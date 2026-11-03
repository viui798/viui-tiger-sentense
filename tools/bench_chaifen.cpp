// Headless 每键耗时探针：拆字滤镜 A/B 对比。
// Usage: bench_chaifen user shared lua-plugin schema raw rounds [segments=N]
// raw 中 \t / \b / \n 分别映射为 Tab / BackSpace / Return。
// 输出单行 JSON：median / p95 / mean / 样本数（微秒），丢弃第一轮预热；
// 可选 segments=N：把全部样本按每 N 键分段输出各段中位数（测长会话漂移）。
#include <rime_api.h>
#include <dlfcn.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    if (argc < 7 || argc > 8 || !*argv[5]) {
        std::fprintf(stderr,
            "usage: bench_chaifen user shared lua-plugin schema raw rounds [segments=N]\n");
        return 2;
    }
    int segment_size = 0;
    if (argc == 8) {
        if (std::sscanf(argv[7], "segments=%d", &segment_size) != 1 || segment_size < 10) {
            std::fprintf(stderr, "segments=N 需要 N>=10\n");
            return 2;
        }
    }
    const int rounds = std::atoi(argv[6]);
    if (rounds < 2) return 2;
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
    traits.app_name = "rime.tiger.chaifen-bench";
    traits.modules = modules;
    traits.min_log_level = 3;
    api->setup(&traits);
    api->initialize(&traits);
    if (api->start_maintenance(True)) api->join_maintenance_thread();
    auto session = api->create_session();
    if (!session || !api->select_schema(session, argv[4])) {
        if (session) api->destroy_session(session);
        api->finalize();
        return 2;
    }
    // 触发 option_persist 的 init 重放，再进入计时。
    api->process_key(session, 'a', 0);
    api->clear_composition(session);

    std::vector<double> times;
    double first_key_us = 0;  // 冷启动后第一键（含 OpenCC 字典首次加载）
    times.reserve(static_cast<size_t>(rounds) * std::string(argv[5]).size());
    for (int r = 0; r < rounds; ++r) {
        for (const unsigned char* p = (const unsigned char*)argv[5]; *p; ++p) {
            int key = *p == '\t' ? 0xff09 : *p == '\b' ? 0xff08
                    : *p == '\n' ? 0xff0d : *p;
            auto t0 = std::chrono::steady_clock::now();
            api->process_key(session, key, 0);
            auto t1 = std::chrono::steady_clock::now();
            double us = std::chrono::duration<double, std::micro>(t1 - t0).count();
            if (r == 0 && p == (const unsigned char*)argv[5]) first_key_us = us;
            if (r > 0) times.push_back(us);
        }
        api->clear_composition(session);
        RIME_STRUCT(RimeCommit, commit);
        if (api->get_commit(session, &commit)) api->free_commit(&commit);
    }
    api->destroy_session(session);
    api->finalize();

    if (times.empty()) return 2;
    std::sort(times.begin(), times.end());
    double sum = 0;
    for (double t : times) sum += t;
    const auto at = [&](double q) {
        return times[std::min(times.size() - 1, (size_t)(q * times.size()))];
    };
    std::printf("{\"median_us\":%.1f,\"p95_us\":%.1f,\"mean_us\":%.1f,"
                "\"min_us\":%.1f,\"max_us\":%.1f,\"first_key_us\":%.1f,"
                "\"samples\":%zu",
                at(0.5), at(0.95), sum / times.size(), times.front(),
                times.back(), first_key_us, times.size());
    if (segment_size > 0) {
        std::printf(",\"segment_size\":%d,\"segments\":[", segment_size);
        for (size_t base = 0; base < times.size(); base += segment_size) {
            size_t end = std::min(times.size(), base + segment_size);
            if (end - base < (size_t)segment_size / 2) break;  // 尾段太短不单独成段
            std::vector<double> seg(times.begin() + base, times.begin() + end);
            std::sort(seg.begin(), seg.end());
            std::printf("%s%.1f", base > 0 ? "," : "", seg[seg.size() / 2]);
        }
        std::printf("]");
    }
    std::printf("}\n");
    return 0;
}
