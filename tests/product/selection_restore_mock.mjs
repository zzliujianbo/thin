// --restore-selection used to open a new chat from only a saved selection.
// No public TUI action has those semantics: /resume continues the old history.
// Retire its success/load-error cases rather than using private worker syntax.
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

export async function selectionRestoreRegressions({app, pty, execute}) {
  const root = await mkdtemp(join(tmpdir(), 'thin-rejected-launch-'));
  const home = join(root,'home'), project = join(root,'project'), runtime = join(root,'runtime');
  const id = '0123456789abcdef0123456789abcdef';
  try {
    for (const dir of [home,project,runtime]) await mkdir(dir,{mode:0o700});
    const env = {PATH:'/usr/bin:/bin',HOME:home,XDG_RUNTIME_DIR:runtime,LANG:'C.UTF-8'};
    for (const args of [
      ['--restore-selection','../bad'], ['--restore-selection',id,'--restore-selection',id],
      ['--restore-selection',id,'--print','not sent'], ['--restore-selection',id],
      ['--print','not sent'], ['-p','not sent'], ['--no-model-auto-refresh'],
      ['--help'], ['-h'], ['--version'], ['--no-log'], ['--print','not sent','--no-log'],
      ['--attach',id], ['--takeover'], ['--connect'], ['--ssh-listen','127.0.0.1:2222'],
    ]) {
      const result = await execute(app,args,env,project);
      assert.equal(result.signal,null);
      assert.equal(result.code,2);
      assert.equal(result.output,'Usage: thin [--daemon]\n');
    }
    for (const dir of [home,project,runtime]) assert.deepEqual(await readdir(dir),[]);
    // A real terminal must not make either removed launch form valid.
    for (const mode of ['restore-selection','reject-print']) {
      const result = await execute(pty,[],{...env,TERM:'xterm-256color',THIN_APP_BIN:app,
        THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:project,THIN_APP_TEST_URL:'http://127.0.0.1:1',
        THIN_APP_TEST_MODE:mode},project);
      assert.equal(result.code,0);
      assert(!result.output.includes('PTY_SESSION_ID='));
    }
    for (const dir of [home,project]) assert.deepEqual(await readdir(dir),[]);
    console.log('PASS removed launch flags: rejected before configuration and session creation');
  } finally { await rm(root,{recursive:true,force:true}); }
}
