///|
/// SARIF export tests. Every test pins `version=` so release bumps to
/// `ENGINE_VERSION` don't churn the snapshots.

///|
fn sarif_entry(
  content : String,
  path? : String,
  kind? : @karinto.FileKind = Unknown,
) -> @karinto.SarifEntry {
  @karinto.SarifEntry::{ path, result: @karinto.lint(content, kind~) }
}

///|
test "sarif_report: finding maps rule/severity/pos/job/step" {
  let yaml =
    #|on: push
    #|permissions: {}
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - id: one
    #|        run: echo hi
    #|      - id: one
    #|        run: echo again
  json_inspect(
    @karinto.sarif_report(
      [sarif_entry(yaml, path=".github/workflows/ci.yml")],
      version="9.9.9-test",
    ),
    content={
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      "version": "2.1.0",
      "runs": [
        {
          "tool": {
            "driver": {
              "name": "karinto",
              "version": "9.9.9-test",
              "informationUri": "https://github.com/toiroakr/karinto",
              "rules": [
                {
                  "id": "duplicate-job-step-ids",
                  "shortDescription": { "text": "Duplicate job/step IDs" },
                  "defaultConfiguration": { "level": "error" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "syntax",
                    "origins": ["actionlint:duplicate-job-step-ids"],
                  },
                },
                {
                  "id": "concurrency-limits",
                  "shortDescription": { "text": "Missing concurrency control" },
                  "defaultConfiguration": { "level": "note" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "performance",
                    "origins": ["zizmor:concurrency-limits"],
                  },
                },
                {
                  "id": "anonymous-definition",
                  "shortDescription": {
                    "text": "Missing name on workflow/action",
                  },
                  "defaultConfiguration": { "level": "note" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "best-practice",
                    "origins": ["zizmor:anonymous-definition"],
                  },
                },
                {
                  "id": "job-timeout-minutes-required",
                  "shortDescription": { "text": "Job timeout-minutes required" },
                  "defaultConfiguration": { "level": "warning" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "best-practice",
                    "origins": [
                      "ghalint:ghl-012 (job_timeout_minutes_is_required)",
                    ],
                  },
                },
              ],
            },
          },
          "columnKind": "utf16CodeUnits",
          "results": [
            {
              "ruleId": "duplicate-job-step-ids",
              "ruleIndex": 0,
              "level": "error",
              "message": {
                "text": "duplicate step ID `one` (conflicts with `one` case-insensitively)",
              },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": {
                      "uri": ".github/workflows/ci.yml",
                      "uriBaseId": "%SRCROOT%",
                    },
                    "region": { "startLine": 9, "startColumn": 9 },
                  },
                  "logicalLocations": [
                    { "name": "build", "kind": "job" },
                    {
                      "name": "one",
                      "fullyQualifiedName": "build/steps[1]",
                      "kind": "step",
                    },
                  ],
                },
              ],
            },
            {
              "ruleId": "concurrency-limits",
              "ruleIndex": 1,
              "level": "note",
              "message": { "text": "workflow has no `concurrency:` block" },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": {
                      "uri": ".github/workflows/ci.yml",
                      "uriBaseId": "%SRCROOT%",
                    },
                  },
                },
              ],
            },
            {
              "ruleId": "anonymous-definition",
              "ruleIndex": 2,
              "level": "note",
              "message": { "text": "workflow has no `name:`" },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": {
                      "uri": ".github/workflows/ci.yml",
                      "uriBaseId": "%SRCROOT%",
                    },
                  },
                },
              ],
            },
            {
              "ruleId": "anonymous-definition",
              "ruleIndex": 2,
              "level": "note",
              "message": { "text": "job `build` has no `name:`" },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": {
                      "uri": ".github/workflows/ci.yml",
                      "uriBaseId": "%SRCROOT%",
                    },
                    "region": { "startLine": 4, "startColumn": 3 },
                  },
                  "logicalLocations": [{ "name": "build", "kind": "job" }],
                },
              ],
            },
            {
              "ruleId": "job-timeout-minutes-required",
              "ruleIndex": 3,
              "level": "warning",
              "message": {
                "text": "job `build` does not declare `timeout-minutes:`",
              },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": {
                      "uri": ".github/workflows/ci.yml",
                      "uriBaseId": "%SRCROOT%",
                    },
                    "region": { "startLine": 4, "startColumn": 3 },
                  },
                  "logicalLocations": [{ "name": "build", "kind": "job" }],
                },
              ],
            },
          ],
        },
      ],
    },
  )
}

///|
test "sarif_report: pathless entry keeps logical locations only" {
  let yaml =
    #|on: push
    #|permissions: {}
    #|jobs:
    #|  build:
    #|    runs-on: ubuntu-latest
    #|    steps:
    #|      - id: one
    #|        run: echo hi
    #|      - id: one
    #|        run: echo again
  json_inspect(
    @karinto.sarif_report([sarif_entry(yaml)], version="9.9.9-test"),
    content={
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      "version": "2.1.0",
      "runs": [
        {
          "tool": {
            "driver": {
              "name": "karinto",
              "version": "9.9.9-test",
              "informationUri": "https://github.com/toiroakr/karinto",
              "rules": [
                {
                  "id": "duplicate-job-step-ids",
                  "shortDescription": { "text": "Duplicate job/step IDs" },
                  "defaultConfiguration": { "level": "error" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "syntax",
                    "origins": ["actionlint:duplicate-job-step-ids"],
                  },
                },
                {
                  "id": "concurrency-limits",
                  "shortDescription": { "text": "Missing concurrency control" },
                  "defaultConfiguration": { "level": "note" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "performance",
                    "origins": ["zizmor:concurrency-limits"],
                  },
                },
                {
                  "id": "anonymous-definition",
                  "shortDescription": {
                    "text": "Missing name on workflow/action",
                  },
                  "defaultConfiguration": { "level": "note" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "best-practice",
                    "origins": ["zizmor:anonymous-definition"],
                  },
                },
                {
                  "id": "job-timeout-minutes-required",
                  "shortDescription": { "text": "Job timeout-minutes required" },
                  "defaultConfiguration": { "level": "warning" },
                  "helpUri": "https://github.com/toiroakr/karinto/blob/main/rules_catalog.md",
                  "properties": {
                    "category": "best-practice",
                    "origins": [
                      "ghalint:ghl-012 (job_timeout_minutes_is_required)",
                    ],
                  },
                },
              ],
            },
          },
          "columnKind": "utf16CodeUnits",
          "results": [
            {
              "ruleId": "duplicate-job-step-ids",
              "ruleIndex": 0,
              "level": "error",
              "message": {
                "text": "duplicate step ID `one` (conflicts with `one` case-insensitively)",
              },
              "locations": [
                {
                  "logicalLocations": [
                    { "name": "build", "kind": "job" },
                    {
                      "name": "one",
                      "fullyQualifiedName": "build/steps[1]",
                      "kind": "step",
                    },
                  ],
                },
              ],
            },
            {
              "ruleId": "concurrency-limits",
              "ruleIndex": 1,
              "level": "note",
              "message": { "text": "workflow has no `concurrency:` block" },
            },
            {
              "ruleId": "anonymous-definition",
              "ruleIndex": 2,
              "level": "note",
              "message": { "text": "workflow has no `name:`" },
            },
            {
              "ruleId": "anonymous-definition",
              "ruleIndex": 2,
              "level": "note",
              "message": { "text": "job `build` has no `name:`" },
              "locations": [
                { "logicalLocations": [{ "name": "build", "kind": "job" }] },
              ],
            },
            {
              "ruleId": "job-timeout-minutes-required",
              "ruleIndex": 3,
              "level": "warning",
              "message": {
                "text": "job `build` does not declare `timeout-minutes:`",
              },
              "locations": [
                { "logicalLocations": [{ "name": "build", "kind": "job" }] },
              ],
            },
          ],
        },
      ],
    },
  )
}

///|
test "sarif_report: parse error becomes a synthetic parse-error result" {
  let yaml =
    #|on: push
    #|jobs: [
  json_inspect(
    @karinto.sarif_report(
      [sarif_entry(yaml, path="bad.yml")],
      version="9.9.9-test",
    ),
    content={
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      "version": "2.1.0",
      "runs": [
        {
          "tool": {
            "driver": {
              "name": "karinto",
              "version": "9.9.9-test",
              "informationUri": "https://github.com/toiroakr/karinto",
              "rules": [
                {
                  "id": "parse-error",
                  "shortDescription": { "text": "YAML parse error" },
                  "defaultConfiguration": { "level": "error" },
                },
              ],
            },
          },
          "columnKind": "utf16CodeUnits",
          "results": [
            {
              "ruleId": "parse-error",
              "ruleIndex": 0,
              "level": "error",
              "message": { "text": "unterminated flow sequence" },
              "locations": [
                {
                  "physicalLocation": {
                    "artifactLocation": {
                      "uri": "bad.yml",
                      "uriBaseId": "%SRCROOT%",
                    },
                  },
                },
              ],
            },
          ],
        },
      ],
    },
  )
}

///|
test "sarif_report: io errors surface as toolExecutionNotifications" {
  json_inspect(
    @karinto.sarif_report(
      [],
      io_errors=[
        @karinto.SarifIoError::{
          path: "missing.yml",
          message: "cannot read file",
        },
      ],
      version="9.9.9-test",
    ),
    content={
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      "version": "2.1.0",
      "runs": [
        {
          "tool": {
            "driver": {
              "name": "karinto",
              "version": "9.9.9-test",
              "informationUri": "https://github.com/toiroakr/karinto",
              "rules": [],
            },
          },
          "columnKind": "utf16CodeUnits",
          "invocations": [
            {
              "executionSuccessful": false,
              "toolExecutionNotifications": [
                {
                  "level": "error",
                  "message": { "text": "cannot read file" },
                  "locations": [
                    {
                      "physicalLocation": {
                        "artifactLocation": {
                          "uri": "missing.yml",
                          "uriBaseId": "%SRCROOT%",
                        },
                      },
                    },
                  ],
                },
              ],
            },
          ],
          "results": [],
        },
      ],
    },
  )
}

///|
test "sarif_report: clean multi-file report has no results" {
  let yaml =
    #|name: ci
    #|on: push
    #|concurrency:
    #|  group: g
    #|  cancel-in-progress: true
    #|permissions: {}
    #|jobs:
    #|  build:
    #|    name: build
    #|    runs-on: ubuntu-latest
    #|    timeout-minutes: 5
    #|    permissions: {}
    #|    steps:
    #|      - run: echo hi
  json_inspect(
    @karinto.sarif_report(
      [sarif_entry(yaml, path="a.yml"), sarif_entry(yaml, path="b.yml")],
      version="9.9.9-test",
    ),
    content={
      "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json",
      "version": "2.1.0",
      "runs": [
        {
          "tool": {
            "driver": {
              "name": "karinto",
              "version": "9.9.9-test",
              "informationUri": "https://github.com/toiroakr/karinto",
              "rules": [],
            },
          },
          "columnKind": "utf16CodeUnits",
          "results": [],
        },
      ],
    },
  )
}
