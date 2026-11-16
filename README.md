# otp

[![Package Version](https://img.shields.io/hexpm/v/pooka_otp?style=for-the-badge&color=75618E)](https://hex.pm/packages/pooka_otp)
[![Hex Docs](https://img.shields.io/website?url=https%3A%2F%2Fpooka-otp.hexdocs.pm%2F&style=for-the-badge&label=hex&up_message=docs&up_color=FF891F&down_message=not%20found&down_color=lightgrey)](https://pooka-otp.hexdocs.pm/)
[![Tests](https://img.shields.io/github/actions/workflow/status/pooka-lang/otp/test.yml?style=for-the-badge&label=tests)](https://github.com/pooka-lang/otp/actions/workflows/test.yml)

Typed OTP processes, servers, supervisors and applications for Pooka.

```sh
pooka add pooka_otp
```

```pooka
module main

import pooka/otp

main() {
  let inbox: otp.Subject(String) = otp.new_subject()
  otp.send(inbox, "hello")
  assert otp.receive(inbox, 1000) == Some("hello")
}
```

Uses the real OTP behaviours. Native Pooka actors can join supervision trees, and callback objects can implement `server.Handler`. Create each typed name or key once and retain it across restarts.

See the [API documentation](https://pooka-otp.hexdocs.pm/) for the rest.

## Licence

Licensed under the [Apache License, Version 2.0](LICENSE).
