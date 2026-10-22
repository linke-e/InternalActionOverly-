// fengari 驱动：① 4 个 lua 文件语法检查（只编译不执行）
//               ② mock 环境下执行逻辑回归 test_logic.lua
import { lua, lauxlib, lualib, to_luastring, to_jsstring } from 'fengari';
import { readFileSync } from 'node:fs';

const MODDIR = 'E:/Cache/RemoteStore/Isaac/internalreactionoverlay+';

// ---- 1) 语法检查 ----
let syntaxFail = 0;
for (const f of [
  'main.lua',
  'internalreactionoverlay_config.lua',
  'internalreactionoverlay_profiles.lua',
  'internalreactionoverlay_frames.lua',
  '.tmp_verify/test_logic.lua',
  '.tmp_verify/mock_env.lua',
]) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const st = lauxlib.luaL_loadfile(L, to_luastring(`${MODDIR}/${f}`));
  if (st !== lua.LUA_OK) {
    syntaxFail++;
    console.log(`SYNTAX FAIL ${f}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
  } else {
    console.log(`SYNTAX OK   ${f}`);
  }
}

// ---- 2) 逻辑回归 ----
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
let st = lauxlib.luaL_dostring(L, to_luastring(readFileSync(`${MODDIR}/.tmp_verify/mock_env.lua`, 'utf8')));
if (st !== lua.LUA_OK) {
  console.log('MOCK ENV ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}
st = lauxlib.luaL_dostring(L, to_luastring(readFileSync(`${MODDIR}/.tmp_verify/test_logic.lua`, 'utf8')));
if (st !== lua.LUA_OK) {
  console.log('RUNTIME ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
  process.exit(1);
}

const out = (st === lua.LUA_OK);
process.exit(syntaxFail === 0 ? 0 : 1);
