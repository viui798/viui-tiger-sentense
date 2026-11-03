// Headless librime-lua A/B, always use an isolated user directory.
// Usage: bench user shared lua-plugin schema on|off raw [rounds]
// on/off controls only pinyin_no_model; normal tiger input can be a control.
#include <rime_api.h>
#include <dlfcn.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <ctime>
#include <sys/resource.h>

int main(int argc, char** argv) {
    if ((argc != 7 && argc != 8) ||
        (std::string(argv[5]) != "on" && std::string(argv[5]) != "off")) {
        std::fprintf(stderr, "usage: bench user shared lua-plugin schema on|off raw [rounds]\n");
        return 2;
    }
    const int rounds = argc == 8 ? std::atoi(argv[7]) : 10;
    if (rounds <= 3 || !*argv[6]) return 2;
    if (!dlopen(argv[3], RTLD_NOW | RTLD_GLOBAL)) {
        std::fprintf(stderr, "plugin: %s\n", dlerror());
        return 2;
    }
    auto api = rime_get_api();
    const char* modules[] = {"default", "lua", nullptr};
    RIME_STRUCT(RimeTraits, traits);
    traits.user_data_dir = argv[1];
    traits.shared_data_dir = argv[2];
    traits.log_dir = argv[1];
    traits.app_name = "rime.tiger.reverse-bench";
    traits.modules = modules;
    traits.min_log_level = 3;
    api->setup(&traits);
    api->initialize(&traits);
    if (api->start_maintenance(True)) api->join_maintenance_thread();
    auto session = api->create_session();
    if (!session || !api->select_schema(session, argv[4])) {
        std::fprintf(stderr, "cannot select schema\n");
        if (session) api->destroy_session(session);
        api->finalize();
        return 2;
    }
    api->set_option(session, "yin", True);
    api->set_option(session, "yin_qp", True);
    for (const char* name : {"yin_flypy", "yin_zrm", "yin_mspy", "yin_sogou"})
        api->set_option(session, name, False);
    api->set_option(session, "pinyin_no_model", std::string(argv[5]) == "off");
    if (const char* prelude = std::getenv("DEEP_PRELUDE")) {
        for (const char* p=prelude; *p; ++p) {
            api->process_key(session, static_cast<unsigned char>(*p), 0);
            RIME_STRUCT(RimeContext, c);
            if(api->get_context(session,&c)) api->free_context(&c);
        }
        api->clear_composition(session);
    }
    std::vector<double> times;
    double cold = 0, key_ms = 0, context_ms = 0, commit_ms = 0;
    const auto cpu_start = std::clock();
    std::string top;
    for (int round = 0; round < rounds; ++round) {
        if(round==3) { auto reset=(void(*)())dlsym(RTLD_DEFAULT,"cheese_gc_reset"); if(reset)reset(); }
        api->clear_composition(session);
        for (const char* p = argv[6]; *p; ++p) {
            auto start = std::chrono::steady_clock::now();
            api->process_key(session, static_cast<unsigned char>(*p), 0);
            auto after_key = std::chrono::steady_clock::now();
            RIME_STRUCT(RimeContext, context);
            if (api->get_context(session, &context)) {
                if (context.menu.num_candidates > 0)
                    top = context.menu.candidates[0].text;
                api->free_context(&context);
            }
            auto after_context = std::chrono::steady_clock::now();
            RIME_STRUCT(RimeCommit, commit);
            if (api->get_commit(session, &commit)) api->free_commit(&commit);
            double elapsed = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            if (round == 0) cold += elapsed;
            if (round >= 3) {
                times.push_back(elapsed);
                key_ms += std::chrono::duration<double,std::milli>(after_key-start).count();
                context_ms += std::chrono::duration<double,std::milli>(after_context-after_key).count();
                commit_ms += std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-after_context).count();
            }
        }
    }
    auto report=(void(*)())dlsym(RTLD_DEFAULT,"cheese_gc_report"); if(report)report();
    struct rusage usage; getrusage(RUSAGE_SELF, &usage);
    std::printf("phase key_ms=%.3f context_ms=%.3f commit_ms=%.3f cpu_ms=%.3f peak_rss_bytes=%ld\n",key_ms/times.size(), context_ms/times.size(),commit_ms/times.size(),1000.0*(std::clock()-cpu_start)/CLOCKS_PER_SEC,usage.ru_maxrss);
    double total = 0;
    for (double v : times) total += v;
    std::sort(times.begin(), times.end());
    const bool disabled = std::string(argv[5]) == "off";
    bool remembered = api->get_option(session, "pinyin_no_model") == disabled;
    api->destroy_session(session);
    session = api->create_session();
    if (session && api->select_schema(session, argv[4])) {
        // The first key replays saved options, matching the production lifecycle.
        api->process_key(session, 'a', 0);
        remembered = remembered && api->get_option(session, "pinyin_no_model") == disabled;
    } else {
        remembered = false;
    }
    std::printf("model=%s keys=%zu cold_sequence_ms=%.3f mean_ms=%.3f "
        "p50_ms=%.3f p95_ms=%.3f max_ms=%.3f top=%s\n",
        argv[5], times.size(), cold, total / times.size(), times[times.size()/2],
        times[(times.size() * 95 + 99) / 100 - 1], times.back(), top.c_str());
    if (session) api->destroy_session(session);
    api->finalize();
    if (!remembered) std::fprintf(stderr, "model option did not survive session recreation\n");
    return remembered ? 0 : 1;
}
