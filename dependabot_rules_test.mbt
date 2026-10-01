///|
fn dependabot_messages(yaml : String, rule : String) -> Array[String] {
  @karinto.lint(yaml, kind=Dependabot).diagnostics
  .filter(fn(d) { d.rule == rule })
  .map(fn(d) { d.message })
}

///|
test "dependabot-version: version 2 is silent" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-version"), content=[])
}

///|
test "dependabot-version: missing version is flagged" {
  let yaml =
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-version"), content=[
    "`version:` is required and must be `2`",
  ])
}

///|
test "dependabot-version: a version other than 2 is flagged" {
  let yaml =
    #|version: 1
    #|updates: []
  json_inspect(dependabot_messages(yaml, "dependabot-version"), content=[
    "`version:` must be `2`, got `1`",
  ])
}

///|
test "dependabot-version: a quoted \"2\" is flagged because the schema requires an integer" {
  let yaml =
    #|version: "2"
    #|updates: []
  json_inspect(dependabot_messages(yaml, "dependabot-version"), content=[
    "`version:` must be `2`, got `2` (a string)",
  ])
}

///|
test "dependabot-update-fields: a complete entry is silent" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directories: [/, /web]
    #|    schedule:
    #|      interval: weekly
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[])
}

///|
test "dependabot-update-fields: missing package-ecosystem is flagged" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - directory: /
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[
    "update entry is missing required `package-ecosystem`",
  ])
}

///|
test "dependabot-update-fields: missing schedule is flagged" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[
    "`npm` update entry is missing required `schedule`",
  ])
}

///|
test "dependabot-update-fields: schedule without interval is flagged" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      day: monday
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[
    "`npm` update entry's `schedule` is missing required `interval`",
  ])
}

///|
test "dependabot-update-fields: an entry in a multi-ecosystem-group may omit schedule" {
  let yaml =
    #|version: 2
    #|multi-ecosystem-groups:
    #|  all:
    #|    schedule:
    #|      interval: weekly
    #|updates:
    #|  - package-ecosystem: github-actions
    #|    directory: /
    #|    multi-ecosystem-group: all
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[])
}

///|
test "dependabot-update-fields: missing directory and directories is flagged" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[
    "`npm` update entry must declare `directory` or `directories`",
  ])
}

///|
test "dependabot-update-fields: an empty directories list counts as missing" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directories: []
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[
    "`npm` update entry must declare `directory` or `directories`",
  ])
}

///|
test "dependabot-update-fields: declaring both directory and directories is flagged" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    directories: [/web]
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-update-fields"), content=[
    "`npm` update entry must declare only one of `directory` or `directories`",
  ])
}

///|
test "dependabot-duplicate-directories: distinct directories are silent" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      interval: daily
    #|  - package-ecosystem: npm
    #|    directories: [/web, /api]
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-duplicate-directories"), content=[])
}

///|
test "dependabot-duplicate-directories: the same directory across blocks of one ecosystem is flagged" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      interval: daily
    #|  - package-ecosystem: npm
    #|    directories: [/web, /]
    #|    schedule:
    #|      interval: weekly
  json_inspect(dependabot_messages(yaml, "dependabot-duplicate-directories"), content=[
    "directory `/` is declared more than once for `npm` updates",
  ])
}

///|
test "dependabot-duplicate-directories: a directory repeated inside one directories list is flagged" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directories: [/web, /web]
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-duplicate-directories"), content=[
    "directory `/web` is declared more than once for `npm` updates",
  ])
}

///|
test "dependabot-duplicate-directories: different ecosystems may share a directory" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      interval: daily
    #|  - package-ecosystem: github-actions
    #|    directory: /
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-duplicate-directories"), content=[])
}

///|
test "dependabot-duplicate-directories: different target-branch values may share a directory" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    schedule:
    #|      interval: daily
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    target-branch: release
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-duplicate-directories"), content=[])
}

///|
test "dependabot-duplicate-directories: the message names a shared target-branch" {
  let yaml =
    #|version: 2
    #|updates:
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    target-branch: release
    #|    schedule:
    #|      interval: daily
    #|  - package-ecosystem: npm
    #|    directory: /
    #|    target-branch: release
    #|    schedule:
    #|      interval: daily
  json_inspect(dependabot_messages(yaml, "dependabot-duplicate-directories"), content=[
    "directory `/` is declared more than once for `npm` updates targeting `release`",
  ])
}
