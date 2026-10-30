# Operations and demonstration runbook

All AWS commands must use the intended profile and region. Examples use `manara` / `us-east-1`;
replace `manara` with your own authenticated profile and match `aws_profile` in your configuration.
Replace names if your `terraform.tfvars` uses another project name. Never dump credentials or
authorization headers into a recording.

## Find a job

Copy the job ID displayed in the UI, then inspect its DynamoDB item:

```bash
aws dynamodb get-item --profile manara --region us-east-1 \
  --table-name manara-images \
  --key '{"job_id":{"S":"REPLACE_WITH_JOB_ID"}}' --consistent-read
```

In Step Functions, open the `manara-images` state machine and select the execution whose name
matches that job ID. Inspect the first failed state and its error/cause. Lambda log groups are
`/aws/lambda/manara-images-<stage>`. The application logs action/job ID, not tokens or image data.
Step Functions error logs omit execution payloads; detailed execution history still contains
S3 references and dimensions, so restrict console/API access appropriately.

## Symptoms

### Upload denied

- 401/403 from the API: check the demo token and deployed authorizer hash. After rotation, every
  browser needs the new token. Do not relax authorization to debug an expired/wrong token.
- S3 403: upload grant may have expired, file length/MIME may not match the policy, or the client
  failed to send all returned form fields before the final `file` field. Create a new grant.
- Browser CORS/CSP errors: use the deployed CloudFront URL. Localhost is deliberately not in
  production CORS. If the region changed, rebuild/redeploy the Terraform configuration.
- 429: wait before retrying. Stage throttling is intentionally low for a demo.

### AWAITING_UPLOAD or QUEUED

- An abandoned upload remains AWAITING_UPLOAD until TTL cleanup; the API exposes an expired-grant
  hint. Start a new upload; do not reuse another job's key.
- Verify the S3 notification, SQS event-source mapping, Lambda dispatcher logs, and queue metrics.
- A QUEUED status can precede StartExecution because those calls are not atomic. Re-delivery
  retries the same execution name and stable input. Do not manually create a new execution name
  for the same job: that bypasses the deduplication contract.
- If dispatch retries exhausted, inspect/redrive the DLQ after fixing the root cause.

### FAILED

- Invalid/corrupt/mismatched/animated/oversized images fail validation. Try a supported static file.
- For service failures, check task IAM permissions, layer/runtime compatibility, regional quotas,
  SDK errors, and configured timeouts. Do not grant `AdministratorAccess` to worker roles.
- The state machine ends with a failure after recording FAILED. This is intentional, so alarms
  and console execution history accurately reflect the outcome.

### COMPLETED but no images or email

- Check result object keys and MIME type, CloudFront OAC bucket policy, and distribution propagation.
  Only `images/*` is readable through OAC; intermediates should remain inaccessible.
- Email requires `notification_email` and a confirmed SNS subscription. Check the subscription's
  confirmation status and your spam folder. No subscriber means publishes without delivered email.
- `NotificationFailed` means image processing succeeded but publishing the SNS notification did
  not. Check KMS/topic permissions and execution history; do not overwrite a COMPLETED job.

## Inspect and redrive the ingestion DLQ

Inspect without deleting (receiving a message temporarily changes its visibility):

```bash
aws sqs receive-message --profile manara --region us-east-1 \
  --queue-url "$(terraform -chdir=infra output -raw dlq_url)" \
  --max-number-of-messages 1 --visibility-timeout 30 --wait-time-seconds 5
```

Fix the dispatch cause first. Then redrive using the SQS console: select `manara-images-dlq`,
choose **Start DLQ redrive**, and move messages back to the original queue at a low rate.
Alternatively use `start-message-move-task` with this project's DLQ/source queue ARNs.
The operator needs the documented SQS redrive permissions; these are not given to image tasks.
The original source version must still exist. If its retention elapsed, create a new upload/job.
Do not purge the queue to dismiss an alarm or blindly redrive malformed events forever.

## Timeout/abort recovery

EventBridge invokes the fail handler for FAILED, TIMED_OUT, and ABORTED executions. Conditional
updates preserve completed jobs and suppress repeat mutation. Service event delivery is
best-effort: check the workflow failure/timeout alarm even if the UI is still PROCESSING.
For a missed recovery event, invoke the failure function with a minimal payload after verifying
that the actual execution is terminal:

```bash
aws lambda invoke --profile manara --region us-east-1 \
  --function-name manara-images-fail --cli-binary-format raw-in-base64-out \
  --payload '{"job_id":"REPLACE_WITH_JOB_ID"}' build/recovery-result.json
```

Do not mark an active execution failed; in-flight tasks can still publish output. A full rerun
uses a new upload/job ID rather than mutating a terminal job or redriving processing states manually.

## Demo recording checklist

1. Show the README architecture diagram and explain the S3→SQS decoupling boundary.
2. Show Terraform's resource plan (not credentials/state files) and explain the runtime roles.
3. Open the live site and enter the token **off camera**. Upload a non-sensitive image.
4. Show status progress and both watermarked result sizes. Explain proportion preservation,
   no upscaling, white transparency background, and removed EXIF metadata.
5. In AWS, show the Standard execution's Validate → Resize → Watermark → Store path and job
   metadata. Show source versioning, private bucket settings, and CloudFront OAC.
6. Upload a corrupt, nonempty `.png` file through the UI, then show FAILED metadata and the
   caught validation failure in execution history.
7. Explain why invalid images do not enter the ingestion DLQ, while dispatch failures do.
8. If configured, show the confirmed SNS notification and relevant CloudWatch alarms.
9. Explain token/result access limitations, retention settings, costs, and cleanup.
10. Add the public repository and optional demo URL/video to the submission.

## Cleanup — destructive, requires a deliberate decision

1. Save any needed originals/results and demo evidence. Record the deployment outputs privately.
2. Keep the current Terraform state and source intact. A rebuild is needed if ZIP artifacts are
   missing, even for some destroy-planning operations.
3. If retaining data, do not destroy its buckets/table; make a separate reviewed retention plan.
4. If you intentionally want to delete **all project data**, set
   `force_destroy_buckets = true` in the ignored `infra/terraform.tfvars`, apply that change with
   a reviewed normal plan, then create/review a destroy plan:

   ```bash
   terraform -chdir=infra plan -destroy -out=../build/destroy.tfplan
   terraform -chdir=infra apply ../build/destroy.tfplan
   ```

   The force-destroy flag allows Terraform to remove source versions, delete markers,
   intermediates, and output objects when destroying project buckets. It does not empty
   arbitrary buckets. Never turn it on casually or for buckets outside this project.

5. CloudFront disabling/deletion may take time. The KMS key is scheduled for deletion with a
   seven-day waiting window; verify that schedule in KMS. Terraform deletes the key alias/topic.
6. Verify that tagged project resources are gone, email subscriptions removed, and the following
   day's billing shows no unexpected ongoing spend. Alarms are not a spending kill switch.
7. Delete local token material only when you no longer need to access the deployment; never
   publish state files, saved plans, or secret material as part of the public project.
