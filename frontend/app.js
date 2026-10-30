"use strict";

const $ = (selector) => document.querySelector(selector);
const form = $("#upload-form");
const fileInput = $("#file");
const submit = $("#submit");
let config;
let previewUrl;
let busy = false;

function status(message, stage, complete = false) {
  $("#status").textContent = message;
  const stages = ["upload", "queue", "process", "done"];
  const current = stages.indexOf(stage);
  document.querySelectorAll("#steps li").forEach((element, index) => {
    element.classList.toggle("active", index === current && !complete);
    element.classList.toggle("done", index < current || (complete && index <= current));
  });
}

function selectedFile() {
  if (busy) return;
  const file = fileInput.files[0];
  if (previewUrl) URL.revokeObjectURL(previewUrl);
  $("#results").hidden = true;
  $("#preview").hidden = true;
  if (!file) return;
  $("#file-label").textContent = file.name;
  $("#file-detail").textContent = `${(file.size / 1024 / 1024).toFixed(2)} MiB · ready to upload`;
  if (!["image/jpeg", "image/png", "image/webp"].includes(file.type) ||
      file.size === 0 || file.size > 10 * 1024 * 1024) {
    fileInput.value = "";
    status("Choose a JPEG, PNG, or WebP image between 1 byte and 10 MiB.");
    return;
  }
  previewUrl = URL.createObjectURL(file);
  $("#preview").src = previewUrl;
  $("#preview").hidden = false;
  status("Original selected. Add your access token and make it yours.");
}

async function request(path, token, body) {
  const result = await fetch(`${config.api_url}${path}`, {
    method: body ? "POST" : "GET",
    headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  });
  if (result.status === 401 || result.status === 403) throw new Error("Access denied. Check your demo token.");
  if (result.status === 429) throw new Error("The studio is busy. Please wait a moment and try again.");
  if (!result.ok) {
    const error = await result.json().catch(() => ({}));
    throw new Error(error.error || `Request failed (${result.status}).`);
  }
  return result.json();
}

function showResults(job) {
  const grid = $("#result-grid");
  grid.replaceChildren();
  for (const [name, url] of Object.entries(job.images)) {
    // Only render URLs from the same CloudFront origin; never insert HTML from API data.
    const safe = new URL(url);
    if (safe.origin !== location.origin || !safe.pathname.startsWith("/images/")) {
      throw new Error("Unexpected image URL returned by the API.");
    }
    const card = document.createElement("article");
    card.className = "result-card";
    const image = document.createElement("img");
    image.src = safe.href;
    image.alt = `Watermarked ${name}`;
    const heading = document.createElement("h3");
    heading.textContent = name === "thumbnail" ? "The thumbnail" : "The larger picture";
    const link = document.createElement("a");
    link.href = safe.href;
    link.textContent = "Open / download image ↗";
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    card.append(image, heading, link);
    grid.append(card);
  }
  $("#results").hidden = false;
}

fileInput.addEventListener("change", selectedFile);
const dropzone = $("#dropzone");
for (const type of ["dragenter", "dragover"]) {
  dropzone.addEventListener(type, (event) => {
    event.preventDefault();
    if (!busy) dropzone.classList.add("dragging");
  });
}
for (const type of ["dragleave", "drop"]) {
  dropzone.addEventListener(type, (event) => {
    event.preventDefault();
    dropzone.classList.remove("dragging");
  });
}
dropzone.addEventListener("drop", (event) => {
  if (busy || !event.dataTransfer.files.length) return;
  const transfer = new DataTransfer();
  transfer.items.add(event.dataTransfer.files[0]);
  fileInput.files = transfer.files;
  selectedFile();
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (busy) return;
  if (!config) {
    status("Backend not configured yet. Deploy the infrastructure to enable uploads.");
    return;
  }
  const file = fileInput.files[0];
  const token = $("#token").value.trim();
  if (!file || !token) return;
  busy = true;
  submit.disabled = true;
  fileInput.disabled = true;
  $("#results").hidden = true;
  $("#job-id").textContent = "";
  let jobId;
  try {
    status("Preparing your private upload…", "upload");
    const grant = await request("/uploads", token, { content_type: file.type, size: file.size });
    jobId = grant.job_id;
    $("#job-id").textContent = `JOB / ${jobId}`;
    const payload = new FormData();
    Object.entries(grant.upload.fields).forEach(([key, value]) => payload.append(key, value));
    payload.append("file", file); // S3 requires the file field last.
    const uploaded = await fetch(grant.upload.url, {
      method: "POST", body: payload, signal: AbortSignal.timeout(120000),
    });
    if (!uploaded.ok) throw new Error(`Upload failed (${uploaded.status}). Create a new upload and retry.`);
    status("Safely uploaded. Waiting for the processing queue…", "queue");
    const deadline = Date.now() + 11 * 60 * 1000;
    let transientErrors = 0;
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 3000));
      let job;
      try {
        job = await request(`/jobs/${jobId}`, token);
        transientErrors = 0;
      } catch (error) {
        if (++transientErrors >= 3) throw error;
        continue;
      }
      if (job.status === "COMPLETED") {
        showResults(job);
        status("Ready. Two fresh frames, with your watermark and without the extra metadata.", "done", true);
        return;
      }
      if (job.status === "FAILED") throw new Error(job.error || "Image processing failed.");
      if (job.status === "PROCESSING") status("Validating, resizing, and adding the finishing touch…", "process");
    }
    throw new Error("Still waiting. Processing may continue; use the job ID to check the workflow.");
  } catch (error) {
    status(error.message || "Something went wrong. Please try again.");
  } finally {
    busy = false;
    submit.disabled = false;
    fileInput.disabled = false;
  }
});

fetch("config.json", { cache: "no-store" }).then(async (result) => {
  if (!result.ok) throw new Error("Missing deployment configuration");
  config = await result.json();
  const url = new URL(config.api_url);
  if (url.protocol !== "https:" || !/^[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com$/.test(url.hostname)) {
    config = undefined;
    throw new Error("Invalid API URL");
  }
  config.api_url = url.origin;
}).catch(() => {
  status("Local preview — the AWS backend has not been deployed yet.");
});
