const fixture =
    \\{"llm":{"default":"p/main","providers":{"p":{"base_url":"https://fixture.invalid/v1","api_key":"fake-main","models":{"main":{"protocol":"chat","context_tokens":65536},"raw/id":{"protocol":"systemone"}}}}},"decision":{"model":"p/raw/id","enabled":false},"limits":{"low_price_input":false},"proxy":{"address":"::1","port":8080,"models":["p/raw/id"]}}
;
