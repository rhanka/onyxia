import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = new URL(".", import.meta.url);
const repoRoot = new URL("../../", root);
const itemsDir = new URL("items/", root);

const kinds = new Set([
  "service",
  "data_source",
  "api",
  "mcp_tool",
  "connector",
  "workflow",
  "iceberg_catalog"
]);

const statuses = new Set([
  "brainstorm",
  "spec",
  "plan",
  "uat",
  "prod",
  "blocked",
  "deprecated"
]);

const uatStatuses = new Set([
  "not_started",
  "in_progress",
  "passed",
  "blocked",
  "not_applicable"
]);

const runtimeHookTypes = new Set([
  "helm_chart",
  "dag",
  "job",
  "mcp_action",
  "api_probe",
  "manual",
  "none"
]);

const runtimeHookStatuses = new Set([
  "draft",
  "planned",
  "available",
  "blocked",
  "not_applicable"
]);

const sensitivityValues = new Set(["public", "internal", "restricted", "unknown"]);

function fail(file, message) {
  throw new Error(`${path.basename(file)}: ${message}`);
}

function assertString(file, obj, key) {
  if (typeof obj[key] !== "string" || obj[key].length === 0) {
    fail(file, `${key} must be a non-empty string`);
  }
}

function assertArray(file, obj, key) {
  if (!Array.isArray(obj[key])) {
    fail(file, `${key} must be an array`);
  }
}

function validateItem(file, item) {
  for (const key of ["id", "kind", "title", "owner", "status", "summary"]) {
    assertString(file, item, key);
  }

  if (!/^[a-z0-9][a-z0-9-]*$/.test(item.id)) {
    fail(file, "id must be kebab-case");
  }
  if (!kinds.has(item.kind)) {
    fail(file, `invalid kind ${item.kind}`);
  }
  if (!statuses.has(item.status)) {
    fail(file, `invalid status ${item.status}`);
  }

  for (const key of ["links", "dependencies", "runtimeHooks"]) {
    assertArray(file, item, key);
  }

  if (typeof item.security !== "object" || item.security === null) {
    fail(file, "security must be an object");
  }
  assertString(file, item.security, "auth");
  assertString(file, item.security, "notes");
  if (!sensitivityValues.has(item.security.sensitivity)) {
    fail(file, `invalid sensitivity ${item.security.sensitivity}`);
  }

  if (typeof item.uat !== "object" || item.uat === null) {
    fail(file, "uat must be an object");
  }
  if (!uatStatuses.has(item.uat.status)) {
    fail(file, `invalid uat.status ${item.uat.status}`);
  }
  assertArray(file, item.uat, "checklists");
  assertArray(file, item.uat, "blockers");

  for (const link of item.links) {
    assertString(file, link, "label");
    assertString(file, link, "href");
    if (!/^[a-z][a-z0-9+.-]*:/.test(link.href)) {
      const target = path.join(repoRoot.pathname, link.href);
      if (!fs.existsSync(target)) {
        fail(file, `link target does not exist: ${link.href}`);
      }
    }
  }

  for (const hook of item.runtimeHooks) {
    if (!runtimeHookTypes.has(hook.type)) {
      fail(file, `invalid runtime hook type ${hook.type}`);
    }
    if (!runtimeHookStatuses.has(hook.status)) {
      fail(file, `invalid runtime hook status ${hook.status}`);
    }
    assertString(file, hook, "target");
  }
}

const files = fs
  .readdirSync(itemsDir)
  .filter(name => name.endsWith(".json"))
  .sort()
  .map(name => path.join(itemsDir.pathname, name));

const items = files.map(file => {
  const item = JSON.parse(fs.readFileSync(file, "utf8"));
  validateItem(file, item);
  return item;
});

const ids = new Set(items.map(item => item.id));
for (const item of items) {
  for (const dependency of item.dependencies) {
    if (!ids.has(dependency)) {
      fail(`${item.id}.json`, `unknown dependency ${dependency}`);
    }
  }
}

console.log(`validated ${items.length} catalog items`);
process.exit(0);
