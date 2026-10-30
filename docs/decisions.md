# Architecture decisions and tradeoffs

## Scope

This is a graduation/demo workload for a small trusted group, not an anonymous upload service.
The assignment determines the core components: source/destination S3, SQS/DLQ, Lambda/Pillow,
Standard Step Functions, an upload-grant API, DynamoDB metadata, CloudFront, and SNS.

## Why these choices

- **Python 3.13 Event Functions on demand:** image-processing handlers are event-triggered,
  and there is no stated continuously utilized traffic requirement. No provisioned concurrency
  or managed-instance baseline is needed. Pillow and the compatible boto3 stack live in a layer.
- **Standard Step Functions:** the PDF explicitly requests a Standard visual workflow.
  Durable Functions would keep orchestration in application code, but would not match that
  deliverable as directly. The four named processing steps are independently visible and retriable.
- **API Gateway HTTP API:** the two authenticated endpoints do not need REST API usage plans,
  caching, transformation, or private APIs. HTTP API avoids unnecessary features/expense.
  This choice means WAF cannot be attached directly to this API; CloudFront WAF protects only
  the frontend/images. Throttling plus a token is a demo baseline, not complete abuse prevention.
- **Presigned POST, not just PUT:** a POST policy can constrain exact upload size as well as MIME
  and key. The browser only receives a short-lived capability for one upload key, not AWS keys.
  The declared MIME type is verified against decoded image content during validation.
- **Versioned source bucket:** presigned grants are reusable until expiration. Pinning a version
  ensures source reads are immutable for a job; later notifications for another version are ignored.
  If two uploads occur, the first successfully claimed notification wins, not necessarily the first
  object version by time. This policy is sufficient for a one-file-per-job demo.
- **Deterministic execution name:** DynamoDB and StartExecution are not a distributed transaction.
  A dispatcher retry resumes a QUEUED job with identical inputs and the same job ID execution name.
  Duplicate notifications do not cause extra state machines. Terminal job statuses cannot regress
  to QUEUED. A completed/failed execution cannot be rerun under that name; create a new upload/job.
- **DynamoDB on demand:** access is one GetItem/UpdateItem by job ID, so a single key is enough.
  No table scan or unnecessary GSI. TTL is for eventual cleanup; the API enforces expiry on reads.
- **Intermediate S3 objects:** state-machine payloads carry references, not binary image data.
  This adds a small number of S3 requests per job but avoids large state payloads and local-disk
  coupling between functions. Intermediate objects expire separately from published results.
- **S3 Standard, not archive tiers:** images are small, temporary, and immediately downloaded.
  Minimum storage durations, transitions, and retrieval charges could defeat tiny-demo savings.
  Lifecycle expiration is more useful than adding archive transitions for this workload.
- **CloudFront OAC:** buckets stay private; only the distribution may read `images/*` and frontend
  assets. The `internal/*` prefix has no CloudFront grant. Default frontend caching is disabled so
  a config/token rotation-related deployment does not require manual invalidations. Images use
  random immutable paths and a one-day TTL.
- **Shared token:** no AWS keys in the browser and only a SHA-256 hash in Lambda/Terraform.
  This intentionally avoids building an unrelated account-management app. Replace it with Cognito
  and per-job ownership for individual users. It is not a substitute for a production identity system.
- **Encrypted SNS with a customer-managed KMS key:** Lambda, Step Functions, and CloudWatch
  can publish to the same encrypted topic with explicitly scoped permissions. The managed SNS
  KMS key cannot be edited to grant CloudWatch the needed service permissions. A custom key
  has an idle cost; see below. S3 uses SSE-S3, SQS uses SSE-SQS, and DynamoDB uses managed
  encryption without additional project-owned keys.

## Failure boundaries

1. **Dispatch failure:** malformed events, missing job, service/API failure → partial batch response,
   retry, then ingestion DLQ after five receives. A DLQ alarm requests operator action. A queued job
   can remain QUEUED until an operator repairs/redrives the dispatch; there is no automatic DLQ job
   mutation. S3's initial `s3:TestEvent` is deliberately acknowledged without starting a job.
2. **Task failure:** SDK transient retries occur inside the task. Step Functions retries Lambda
   transport/throttling errors, then catches task failures, marks the job FAILED, publishes a failure
   event, and fails the execution. Invalid images are not endlessly retried through SQS.
3. **Whole execution timeout/abort:** EventBridge invokes the recovery function. The job update is
   conditional: COMPLETED/FAILED jobs are not overwritten. EventBridge service notifications are
   best-effort; alarms plus the operations runbook remain the backstop, not an exactly-once guarantee.
4. **Notification failure after completion:** images remain COMPLETED. The execution fails with
   `NotificationFailed`, triggering a workflow alarm. Recovery does not turn a successful image job
   into a failed one. SNS/consumer delivery itself remains at-least-once, so subscribers deduplicate
   on job ID if necessary.

## Security boundaries

- The token is entered manually and kept only in the page's memory. It is never placed in URLs,
  localStorage, analytics, logs, or source code. Token authorizer caching is disabled.
- API and bucket CORS allow only the deployed CloudFront origin. CORS is not authentication and
  does not prevent non-browser clients from using a valid token.
- Runtime roles are separate for API, dispatcher, each processing stage, and recovery. Source
  readers can read only source versions; only Store can publish into the result prefix.
- Step Functions trust is constrained to the named state machine and account. S3→SQS and
  CloudWatch→SNS grants include source ARN/account checks. CloudFront OAC is constrained to
  its distribution ARN. Lambda execution-role trust uses Lambda's supported service-principal
  pattern rather than unsupported source-context restrictions.
- CloudFront sends CSP, HSTS, no-referrer, nosniff, and frame-denial headers.
- Pillow rejects unsafe pixel counts and animated inputs, applies EXIF orientation, strips
  metadata, and normalizes output. This is not a general-purpose malware-scanning service.
- For public/production use, add per-user quotas, result authorization (signed URLs/cookies),
  protected API ingress, security monitoring, dependency scanning, and a dedicated deployment role.
- Recommended additional auditing: S3 server access logs, CloudTrail S3/Lambda data events,
  CloudFront access logs, and S3 request metrics. They are not enabled in this demo to avoid
  silently creating account-wide audit infrastructure or additional usage/retention costs.
  CloudTrail event history is not a replacement for object-level data-event logging.

## Cost controls and remaining risks

No resources are deployed by building, `terraform validate`, or `terraform plan`.
Deployment and live application evaluation incur charges. No promise of Free Tier eligibility is made.

Usage costs include Lambda compute/requests, S3 storage and GET/PUT/COPY requests, SQS requests,
Step Functions transitions, API requests, DynamoDB storage/operations, CloudFront requests/transfer,
SNS/KMS usage, and CloudWatch logs/alarms. The customer-managed KMS key and CloudWatch alarms
have recurring costs even when no one uploads; DynamoDB point-in-time recovery adds storage cost.
Optional WAF adds its own standing and request charges. Source versioning stores overwritten
versions until lifecycle cleanup. This project does not impose a hard daily upload quota or a hard
spending cap. API throttling limits rate, not cumulative expenditure or all unauthorized-request cost.

Before deployment:

1. Set a monthly budget and email alerts in AWS Budgets. Choose a real ceiling with the account
   owner; this repository does not invent a budget or subscribe an unprovided email address.
2. Review the current service pricing for your region, especially the idle KMS/alarm costs.
3. Use non-sensitive demo images, keep the demo token private, and limit the deployment lifetime.
4. Delete/disable resources deliberately after recording evidence; inspect the following day's bill.

Pricing references (no fixed dollar estimate is claimed):
[S3](https://aws.amazon.com/s3/pricing/), [Lambda](https://aws.amazon.com/lambda/pricing/),
[Step Functions](https://aws.amazon.com/step-functions/pricing/),
[API Gateway](https://aws.amazon.com/api-gateway/pricing/),
[DynamoDB](https://aws.amazon.com/dynamodb/pricing/), [SQS](https://aws.amazon.com/sqs/pricing/),
[CloudFront](https://aws.amazon.com/cloudfront/pricing/), [SNS](https://aws.amazon.com/sns/pricing/),
[KMS](https://aws.amazon.com/kms/pricing/), [CloudWatch](https://aws.amazon.com/cloudwatch/pricing/),
[WAF](https://aws.amazon.com/waf/pricing/).
