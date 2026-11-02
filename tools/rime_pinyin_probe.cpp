// Headless real librime + librime-lua verification for the v0.4.0 pinyin
// reverse-lookup engine (tiger_sentence_pinyin.lua). Runs the production
// schema in an isolated user dir; no desktop IME involved.
//
// Usage: rime_pinyin_probe <user-data-dir> <shared-data-dir> <librime-lua-plugin>
//
// 覆盖（对应 docs/项目日志.md §10.6 实机清单的自动化部分）：
//   1. 小鹤反查：`nihc → 你好（五阶模型引擎候选）+〔拆分·虎码〕注释在位
//   2. 全拼反查：`nihao → 你好；全拼简拼 'jsj → 计算机、'nh → 你好
//   3. （v0.3.3 起后缀式反查已移除） 选首 → 上屏「你好」且反引号被剥除（db.lua 契约）
//   4. 音码总开关：yin 关 → `nihao 零候选；开 → 恢复
//   5. 虎码主路径回归：vp → 刘（提前上屏）
//   6. 虎单反查（万象词库路径）不受影响：`nihao 有候选
#include <rime_api.h>
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
RimeApi* api = nullptr;
RimeSessionId session = 0;
unsigned checks = 0;
std::string committed;

void check(bool ok, const char* message) {
    ++checks;
    if (!ok) throw std::runtime_error(message);
}

void drain() {
    RIME_STRUCT(RimeCommit, c);
    if (api->get_commit(session, &c)) {
        if (c.text) committed += c.text;
        api->free_commit(&c);
    }
}

void key(int code, int modifiers = 0) {
    check(api->process_key(session, code, modifiers), "key not consumed");
    drain();
}

void type(const std::string& text) {
    for (unsigned char c : text) key(c);
}

std::string input() {
    const char* p = api->get_input(session);
    return p ? p : "";
}

struct Cand { std::string text; std::string comment; };

std::vector<Cand> candidates() {
    std::vector<Cand> out;
    RIME_STRUCT(RimeContext, c);
    if (!api->get_context(session, &c)) return out;
    if (c.menu.num_candidates > 0 && c.menu.candidates) {
        for (int i = 0; i < c.menu.num_candidates; ++i) {
            Cand cand;
            if (c.menu.candidates[i].text) cand.text = c.menu.candidates[i].text;
            if (c.menu.candidates[i].comment) cand.comment = c.menu.candidates[i].comment;
            out.push_back(cand);
        }
    }
    api->free_context(&c);
    return out;
}

bool has_candidate(const std::vector<Cand>& cands, const std::string& text) {
    for (const auto& c : cands) if (c.text == text) return true;
    return false;
}

// 翻页收集全菜单（menu page_size=5，首键简拼的目标词可能不在第一页）
std::vector<Cand> candidates_all_pages(int max_pages = 8) {
    std::vector<Cand> out = candidates();
    for (int page = 1; page < max_pages; ++page) {
        RIME_STRUCT(RimeContext, c);
        bool has_next = false;
        if (api->get_context(session, &c)) {
            has_next = c.menu.is_last_page == False;
        }
        api->free_context(&c);
        if (!has_next) break;
        if (!api->process_key(session, 0xff56 /*Page_Down*/, 0)) break;
        drain();
        auto page_cands = candidates();
        out.insert(out.end(), page_cands.begin(), page_cands.end());
    }
    api->clear_composition(session);
    drain();
    return out;
}

void clear_all() {
    api->clear_composition(session);
    drain();
    committed.clear();
}

void radio(const char* on) {
    const char* schemes[] = {"yin_flypy", "yin_qp", "yin_zrm", "yin_mspy", "yin_sogou"};
    for (const char* s : schemes) api->set_option(session, s, std::string(s) == on);
}
}  // namespace

int main(int argc, char** argv) {
    try {
        check(argc == 4, "Usage: rime_pinyin_probe <user-dir> <shared-dir> <lua-plugin>");
        api = rime_get_api();
        check(dlopen(argv[3], RTLD_NOW | RTLD_GLOBAL) != nullptr, "Cannot load librime-lua plugin");
        const char* modules[] = {"default", "lua", nullptr};
        RIME_STRUCT(RimeTraits, traits);
        traits.shared_data_dir = argv[2];
        traits.user_data_dir = argv[1];
        traits.log_dir = argv[1];
        traits.app_name = "rime.tiger.pinyin-probe";
        traits.modules = modules;
        api->setup(&traits);
        api->initialize(&traits);
        if (api->start_maintenance(True)) api->join_maintenance_thread();
        session = api->create_session();
        check(session != 0, "Cannot create Rime session");
        check(api->select_schema(session, "tiger_sentence"), "Cannot select tiger_sentence");

        api->set_option(session, "yin", True);
        api->set_option(session, "tiger_sentence_early_commit", True);

        // ---- 5. 虎码主路径回归（先跑，顺便触发模型加载） ----
        // 提前上屏需要下一键冲刷：vp 唯一确定「刘」，第三键 a 进来时提交「刘」、保留 a。
        clear_all();
        type("vpa");
        check(committed == "刘" && input() == "a", "tiger primary path regressed (vpa->刘+a)");

        // ---- 1. 小鹤反查：'nihc → 你好 + 拆分·虎码注释 ----
        clear_all();
        radio("yin_flypy");
        type("`nihc");
        auto cands = candidates();
        check(!cands.empty(), "flypy reverse lookup produced no candidates");
        check(has_candidate(cands, "你好"), "flypy 'nihc missing 你好 (engine candidates)");
        bool chaifen_seen = false;
        for (const auto& c : cands) {
            if (c.comment.find("〔") != std::string::npos &&
                c.comment.find("·") != std::string::npos) chaifen_seen = true;
        }
        check(chaifen_seen, "〔拆分·虎码〕comment missing on reverse-lookup candidates");
        api->clear_composition(session);
        drain();

        // ---- 2. 全拼反查 + 简拼 ----
        radio("yin_qp");
        type("`nihao");
        cands = candidates();
        check(has_candidate(cands, "你好"), "qp 'nihao missing 你好");
        api->clear_composition(session);
        drain();

        type("`jsj");
        cands = candidates();
        check(has_candidate(cands, "计算机"), "qp 'jsj missing 计算机 (word-initial code)");
        api->clear_composition(session);
        drain();

        type("`nh");
        cands = candidates_all_pages();
        check(has_candidate(cands, "你好"), "qp 'nh missing 你好 (word-initial code)");
        drain();

        // ---- 3. 后缀式反查（v0.3.3 已移除）：nihao` 不再出拼音候选 ----
        clear_all();
        type("nihao`");
        check(!has_candidate(candidates(), "你好"), "suffix-form reverse lookup should be gone");
        clear_all();

        // ---- 4. 音码总开关 ----
        api->set_option(session, "yin", False);
        clear_all();
        type("`nihao");
        check(candidates().empty(), "yin=off must silence the reverse lookup");
        api->set_option(session, "yin", True);

        // ---- 6. 虎单反查（万象词库路径）不受影响 ----
        check(api->select_schema(session, "tiger"), "Cannot select tiger schema");
        clear_all();
        type("`nihc");  // 切 schema 会按 tiger.options.yaml 恢复小鹤打法
        cands = candidates();
        check(!cands.empty() && has_candidate(cands, "你好"),
              "tiger (wanxiang path) reverse lookup regressed");

        std::cout << "{\"status\":\"passed\",\"pinyin_probe_checks\":" << checks << "}"
                  << std::endl;
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "FAIL after " << checks << " checks: " << e.what()
                  << " (input=" << input() << ", committed=" << committed << ")" << std::endl;
        return 1;
    }
}
