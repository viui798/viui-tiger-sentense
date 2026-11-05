// 反查系统四特性审计探针（无头真实 librime）。
// 用法: fancha_probe <user-dir> <shared-dir> <lua-plugin> <case-file>
// case-file 每行: <模式flypy|qp>\t<输入>\t<期望包含的候选文本|->\t<选重序号|->
//   输入按字面键入（` = 反引号 0x60，; ' 数字原样）；
//   期望文本 = 断言该文本出现在候选列表（打满 8 页）；
//   选重序号 = 键入后按数字键 n 选择第 n 个候选并提交（用于调频序列）。
// 输出: 每行 JSON {input, expected, found_at, top3:[...], ok}。
#include <rime_api.h>
#include <dlfcn.h>
#include <algorithm>
#include <iostream>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
RimeApi* api = nullptr;
RimeSessionId session = 0;

void radio(const char* on) {
    const char* schemes[] = {"yin_flypy", "yin_qp", "yin_zrm", "yin_mspy", "yin_sogou"};
    for (const char* s : schemes) api->set_option(session, s, std::string(s) == on);
    api->set_option(session, "yin", True);
    api->set_option(session, "ascii_mode", False);
    api->set_option(session, "tiger_sentence_early_commit", False);
    // 诊断：set_option 是否生效（M.options 的通知器/重放可能回写）
    for (const char* s : schemes) {
        std::fprintf(stderr, "[radio] %s = %d\n", s, api->get_option(session, s));
    }
}

void clear_all() {
    api->clear_composition(session);
    RIME_STRUCT(RimeCommit, c);
    if (api->get_commit(session, &c)) api->free_commit(&c);
}

struct Cand { std::string text; std::string comment; };

std::vector<Cand> page_candidates() {
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

// 打满多页收集候选
std::vector<Cand> all_candidates(int max_pages = 8) {
    std::vector<Cand> out = page_candidates();
    for (int page = 1; page < max_pages; ++page) {
        RIME_STRUCT(RimeContext, c);
        bool has_next = false;
        if (api->get_context(session, &c)) has_next = c.menu.is_last_page == False;
        api->free_context(&c);
        if (!has_next) break;
        if (!api->process_key(session, 0xff56 /*Page_Down*/, 0)) break;
        auto more = page_candidates();
        bool changed = !more.empty();
        out.insert(out.end(), more.begin(), more.end());
        if (!changed) break;
    }
    return out;
}

int find_at(const std::vector<Cand>& cands, const std::string& text) {
    for (size_t i = 0; i < cands.size(); ++i)
        if (cands[i].text == text) return static_cast<int>(i);
    return -1;
}

void type_keys(const std::string& keys) {
    for (unsigned char c : keys) api->process_key(session, c, 0);
}

std::string json_escape(const std::string& s) {
    std::string out;
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += (char)c; }
        else if (c < 0x20) { char buf[8]; std::snprintf(buf, 8, "\\u%04x", c); out += buf; }
        else out += (char)c;
    }
    return out;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc != 5) {
        std::cerr << "usage: fancha_probe <user-dir> <shared-dir> <lua-plugin> <case-file>\n";
        return 2;
    }
    api = rime_get_api();
    if (!dlopen(argv[3], RTLD_NOW | RTLD_GLOBAL)) {
        std::cerr << "plugin: " << dlerror() << "\n";
        return 2;
    }
    const char* modules[] = {"default", "lua", nullptr};
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = argv[2];
    traits.user_data_dir = argv[1];
    traits.log_dir = argv[1];
    traits.app_name = "rime.tiger.fancha-audit";
    traits.modules = modules;
    api->setup(&traits);
    api->initialize(&traits);
    if (api->start_maintenance(True)) api->join_maintenance_thread();
    session = api->create_session();
    if (!session || !api->select_schema(session, "tiger_sentence")) return 2;

    std::ifstream cases(argv[4]);
    std::string line;
    while (std::getline(cases, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::stringstream ss(line);
        std::string mode, input, expected, pick;
        std::getline(ss, mode, '\t');
        std::getline(ss, input, '\t');
        std::getline(ss, expected, '\t');
        std::getline(ss, pick, '\t');

        clear_all();
        radio(mode.c_str());
        type_keys(input);
        auto cands = all_candidates();
        int at = expected == "-" ? -2 : find_at(cands, expected);
        std::string top3 = "[";
        for (size_t i = 0; i < cands.size() && i < 3; ++i) {
            if (i) top3 += ",";
            top3 += "\"" + json_escape(cands[i].text) + "\"";
        }
        top3 += "]";
        std::cout << "{\"input\":\"" << json_escape(input)
                  << "\",\"mode\":\"" << mode
                  << "\",\"expected\":\"" << json_escape(expected)
                  << "\",\"found_at\":" << at
                  << ",\"count\":" << cands.size()
                  << ",\"top3\":" << top3 << "}\n";

        if (pick != "-") {
            // 回到该输入态，按数字键选择第 n 个候选并提交（调频序列用）
            clear_all();
            type_keys(input);
            int n = std::atoi(pick.c_str());
            api->process_key(session, '0' + n, 0);
            RIME_STRUCT(RimeCommit, c);
            if (api->get_commit(session, &c)) api->free_commit(&c);
            api->clear_composition(session);
        }
    }
    return 0;
}
