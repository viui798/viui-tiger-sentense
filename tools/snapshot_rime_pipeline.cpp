// Native candidate/commit regression probe. Use disposable user directories.
// Build against rime_api.h and librime, as for bench_rime_reverse.cpp.
// Usage: snapshot user shared lua-plugin schema raw [option ...]
// raw: TAB selects next; BS deletes; LF confirms. Options use !name to disable.
#include <rime_api.h>
#include <dlfcn.h>
#include <cstdio>
#include <string>

static void field(const char* text) {
    if (text) for (const unsigned char* p = (const unsigned char*)text; *p; ++p)
        std::printf("%02x", *p);
    std::putchar('|');
}

int main(int argc, char** argv) {
    if (argc < 6) return 2;
    if (!dlopen(argv[3], RTLD_NOW | RTLD_GLOBAL)) return 2;
    auto api = rime_get_api();
    const char* modules[] = {"default", "lua", nullptr};
    RIME_STRUCT(RimeTraits, traits);
    traits.user_data_dir = argv[1]; traits.shared_data_dir = argv[2];
    traits.log_dir = argv[1]; traits.app_name = "rime.tiger.snapshot";
    traits.modules = modules; traits.min_log_level = 3;
    api->setup(&traits); api->initialize(&traits);
    if (api->start_maintenance(True)) api->join_maintenance_thread();
    auto session = api->create_session();
    if (!session || !api->select_schema(session, argv[4])) {
        if (session) api->destroy_session(session);
        api->finalize(); return 2;
    }
    // Replay persisted defaults before applying test overrides.
    api->process_key(session, 'a', 0); api->clear_composition(session);
    for (int i = 6; i < argc; ++i)
        api->set_option(session, argv[i] + (argv[i][0] == '!'), argv[i][0] != '!');
    for (const unsigned char* p = (const unsigned char*)argv[5]; *p; ++p) {
        int key = *p == '\t' ? 0xff09 : *p == '\b' ? 0xff08 : *p == '\n' ? 0xff0d : *p;
        std::printf("key=%d accepted=%d|", key, api->process_key(session, key, 0));
        RIME_STRUCT(RimeContext, context);
        if (api->get_context(session, &context)) {
            field(context.composition.preedit);
            std::printf("cursor=%d,%d,%d menu=%d,%d,%d,%d|",
                context.composition.cursor_pos, context.composition.sel_start,
                context.composition.sel_end, context.menu.page_no,
                context.menu.is_last_page, context.menu.highlighted_candidate_index,
                context.menu.num_candidates);
            for (int i = 0; i < context.menu.num_candidates; ++i) {
                const auto& c = context.menu.candidates[i];
                field(c.text); field(c.comment);
            }
            api->free_context(&context);
        }
        RIME_STRUCT(RimeCommit, commit);
        if (api->get_commit(session, &commit)) { field(commit.text); api->free_commit(&commit); }
        std::putchar('\n');
    }
    api->destroy_session(session); api->finalize();
    return 0;
}
