// fengari 驱动：① lua 文件语法检查（只编译不执行）
//               ② mock 环境下执行逻辑回归 test_logic.lua + test_v16.lua
// 运行：node .tmp_verify/verify.mjs（模组目录由本文件位置推导，注入 IRO_MODDIR）
import { lua, lauxlib, lualib, to_luastring, to_jsstring } from 'fengari';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const MODDIR = resolve(dirname(fileURLToPath(import.meta.url)), '..');
process.env.IRO_MODDIR = MODDIR.replace(/\\/g, '/');

let exitCode = 0;

// ---- 1) 语法检查 ----
for (const f of [
  'main.lua',
  'internalreactionoverlay_config.lua',
  'internalreactionoverlay_profiles.lua',
  'internalreactionoverlay_frames.lua',
  '.tmp_verify/test_logic.lua',
  '.tmp_verify/test_v16.lua',
  '.tmp_verify/mock_env.lua',
]) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  const st = lauxlib.luaL_loadfile(L, to_luastring(`${MODDIR}/${f}`));
  if (st !== lua.LUA_OK) {
    exitCode = 1;
    console.log(`SYNTAX FAIL ${f}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
  } else {
    console.log(`SYNTAX OK   ${f}`);
  }
}

// ---- 2) 逻辑回归（每个测试文件独立的干净 Lua 状态）----
for (const f of ['.tmp_verify/test_logic.lua', '.tmp_verify/test_v16.lua']) {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  let st = lauxlib.luaL_dostring(L, to_luastring(readFileSync(`${MODDIR}/.tmp_verify/mock_env.lua`, 'utf8')));
  if (st !== lua.LUA_OK) {
    console.log(`MOCK ENV ERROR: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    process.exit(1);
  }
  st = lauxlib.luaL_dostring(L, to_luastring(readFileSync(`${MODDIR}/${f}`, 'utf8')));
  if (st !== lua.LUA_OK) {
    console.log(`RUNTIME ERROR ${f}: ${to_jsstring(lua.lua_tostring(L, -1))}`);
    process.exit(1);
  }
}

process.exit(exitCode);
