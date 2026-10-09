/* Test-only Lua 5.4 script runner; counts requested Lua heap bytes, not iOS
 * footprint, allocator overhead, native Rime/LevelDb/UI, or OS file cache.
 * cc -O2 tools/lua_memory_runner.c $(pkg-config --cflags --libs lua5.4) -o lua-memory
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
static size_t current_bytes, peak_bytes, allocation_calls, growth_bytes;
static void *count_alloc(void *ud, void *ptr, size_t old_size, size_t new_size) {
  (void)ud;
  if (!ptr) old_size = 0; /* Lua passes an object type for a new allocation. */
  if (!new_size) {
    free(ptr);
    current_bytes -= old_size;
    return NULL;
  }
  void *next = realloc(ptr, new_size);
  if (next) {
    ++allocation_calls;
    if (new_size > old_size) growth_bytes += new_size - old_size;
    current_bytes = current_bytes - old_size + new_size;
    if (current_bytes > peak_bytes) peak_bytes = current_bytes;
  }
  return next;
}
static int memory(lua_State *L) {
  if (lua_toboolean(L, 1)) peak_bytes = current_bytes;
  lua_pushinteger(L, (lua_Integer)current_bytes);
  lua_pushinteger(L, (lua_Integer)peak_bytes);
  return 2;
}
static int allocations(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)allocation_calls);
  lua_pushinteger(L, (lua_Integer)growth_bytes);
  return 2;
}
int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s script.lua [args]\n", argv[0]);
    return 2;
  }
  if (!strcmp(argv[1], "-v")) { puts(LUA_RELEASE); return 0; }
  lua_State *L = lua_newstate(count_alloc, NULL);
  if (!L) return 2;
  luaL_openlibs(L);
  lua_pushcfunction(L, memory);
  lua_setglobal(L, "__memory");
  lua_pushcfunction(L, allocations);
  lua_setglobal(L, "__allocations");
  lua_createtable(L, argc, 0);
  for (int i = 0; i < argc; ++i) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - 1);
  }
  lua_setglobal(L, "arg");
  int status = !strcmp(argv[1], "-e")
      ? (argc > 2 ? luaL_loadstring(L, argv[2]) : LUA_ERRSYNTAX)
      : luaL_loadfile(L, argv[1]);
  if (status == LUA_OK) status = lua_pcall(L, 0, LUA_MULTRET, 0);
  if (status != LUA_OK) {
    const char *message = lua_tostring(L, -1);
    fprintf(stderr, "%s\n", message ? message : "Lua script failed");
  }
  lua_close(L);
  return status == LUA_OK ? 0 : 1;
}
