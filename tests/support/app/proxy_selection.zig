const fixture =
    \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main","models":{"main":{"protocol":"chat","context_tokens":65536},"raw/id":{"protocol":"chat","context_tokens":32768}}}}},"limits":{"request_timeout_ms":12345},"proxy":{"address":"::1","port":8080,"models":["p/raw/id"]}}
;
