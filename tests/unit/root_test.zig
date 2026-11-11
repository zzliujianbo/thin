test "unit test inventory is nonempty" {
    if (@import("builtin").test_functions.len <= 1) return error.NoMatchingProductTests;
}
