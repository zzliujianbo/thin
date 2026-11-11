test "headless real tools: ordinary operations never ask, frozen startup Memory and live reads" {
    try scenario(true);
}
test "headless real tools: denying all mutations creates no files or Memory" {
    try scenario(false);
}
test "runtime asks before dangerous bash and runs ordinary bash without asking" {
    try bashApproval("rm -f .ssh/fixture-marker", .deny, true, false);
    try bashApproval("rm -f .ssh/fixture-marker", .allow_once, true, true);
    try bashApproval("find absent -delete", .deny, false, true);
    try bashApproval("git clean -f -- build/generated", .deny, false, true);
    try bashApproval("rm -rf build", .deny, false, true);
    try bashApproval("printf ok > safe.txt", .deny, false, true);
}
