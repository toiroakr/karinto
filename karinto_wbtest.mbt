///|
test "glob_match exact" {
  inspect(glob_match("ghl-001", "ghl-001"), content="true")
  inspect(glob_match("ghl-001", "ghl-002"), content="false")
}

///|
test "glob_match wildcard prefix" {
  inspect(glob_match("ghl-*", "ghl-001"), content="true")
  inspect(glob_match("ghl-*", "act-id-unique"), content="false")
}

///|
test "glob_match wildcard middle" {
  inspect(glob_match("act-*-unique", "act-id-unique"), content="true")
  inspect(glob_match("act-*-unique", "act-id-format"), content="false")
}

///|
test "glob_match question mark" {
  inspect(glob_match("act-?d-unique", "act-id-unique"), content="true")
  inspect(glob_match("act-?d-unique", "act-xx-unique"), content="false")
}
