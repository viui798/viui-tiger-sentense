// Exercise real librime selection, submission, LevelDb and model ranking.
// All user data belongs to the test runner; no desktop IME is modified.
#include <rime_api.h>
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
#include <string>

static RimeApi* api;
static RimeSessionId session;
static std::string raw_code = "zhhbi";
static std::string correction_level = "off";
static void check(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
}
static std::string first() {
    RIME_STRUCT(RimeContext, ctx);
    check(api->get_context(session, &ctx), "missing context");
    std::string text = ctx.menu.num_candidates ? ctx.menu.candidates[0].text : "";
    api->free_context(&ctx);
    return text;
}
static int position(const std::string& text) {
    RIME_STRUCT(RimeContext, ctx);
    check(api->get_context(session, &ctx), "missing candidate context");
    int index = -1;
    for (int i = 0; i < ctx.menu.num_candidates; ++i)
        if (std::string(ctx.menu.candidates[i].text) == text) index = i;
    api->free_context(&ctx);
    return index;
}
static std::string menu_prefix() {
    RIME_STRUCT(RimeContext, ctx);
    check(api->get_context(session, &ctx), "missing menu snapshot");
    std::string text;
    for (int i = 0; i < ctx.menu.num_candidates && i < 4; ++i) {
        if (i) text += " / ";
        text += ctx.menu.candidates[i].text;
    }
    api->free_context(&ctx);
    return text;
}
static void type() {
    for (char c : raw_code)
        check(api->process_key(session, c, 0), "code key rejected");
}
static void start() {
    session = api->create_session();
    check(session != 0, "session creation failed");
    check(api->select_schema(session, "tiger_sentence"), "schema selection failed");
    api->set_option(session, "ascii_mode", False);
    api->set_option(session, "tiger_sentence_early_commit", False);
    for (const std::string level : {"off", "weak", "medium", "strong"})
        api->set_option(session, ("tiger_sentence_correction_" + level).c_str(), level == correction_level);
}
int main(int argc, char** argv) {
    try {
        check(argc >= 5 && argc <= 7, "usage: probe user shared plugin selection [composed|fusion] [off|weak|medium|strong]");
        const std::string test_case = argc >= 6 ? argv[5] : "composed";
        correction_level = argc == 7 ? argv[6] : "off";
        check(correction_level == "off" || correction_level == "weak" ||
            correction_level == "medium" || correction_level == "strong", "unknown correction level");
        check(test_case == "composed" || test_case == "fusion", "unknown learning case");
        const bool fusion = test_case == "fusion";
        raw_code = fusion ? "ujkf" : "zhhbi";
        const std::string baseline = fusion ? "拾滑" : "其父";
        const std::string target = fusion ? "捡" : "虎娘";
        const std::string selection = argv[4];
        const bool continuation = selection.find("continue") != std::string::npos;
        const bool comma = selection.find("comma") != std::string::npos;
        const bool period = selection.find("period") != std::string::npos;
        api = rime_get_api();
        check(dlopen(argv[3], RTLD_NOW | RTLD_GLOBAL), "Lua plugin load failed");
        const char* modules[] = {"default", "lua", nullptr};
        RIME_STRUCT(RimeTraits, traits);
        traits.user_data_dir = argv[1]; traits.shared_data_dir = argv[2];
        traits.log_dir = argv[1]; traits.app_name = "rime.tiger.learning";
        traits.modules = modules;
        api->setup(&traits); api->initialize(&traits);
        if (api->start_maintenance(True)) api->join_maintenance_thread();
        start(); type();
        if (correction_level != "off") std::cout << "before: " << menu_prefix() << std::endl;
        check(position(baseline) >= 0 && position(target) > position(baseline), "unexpected model baseline");
        if (correction_level == "off") check(first() == baseline, "unexpected first model baseline");
        if (correction_level != "off")
            check(fusion && position("轮滑") >= 0 && position("轮滑") < position(target),
                "corrected candidate must precede the exact target");
        auto learned = [&] {
            return first() == target && position(baseline) > position(target);
        };
        if (selection.find("buffer") != std::string::npos) {
            api->set_option(session, "tiger_sentence_early_commit", True);
            api->set_option(session, "tiger_sentence_early_commit_to_preedit", True);
        }
        RIME_STRUCT(RimeContext, ctx);
        check(api->get_context(session, &ctx), "missing correction menu");
        int index = -1;
        for (int i = 0; i < ctx.menu.num_candidates; ++i)
            if (std::string(ctx.menu.candidates[i].text) == target) index = i;
        api->free_context(&ctx);
        check(index > 0, "target must start as a non-first candidate");
        if (std::string(argv[4]) == "tap") {
            check(api->select_candidate(session, index), "candidate tap rejected");
        } else {
            for (int i = 0; i < index; ++i)
                check(api->process_key(session, 0xff09, 0), "Tab rejected");
            if (continuation)
                for (char c : std::string("tuja"))
                    check(api->process_key(session, c, 0), "continuation rejected");
            check(api->process_key(session, comma ? ',' : period ? '.' : ' ', 0), "commit key rejected");
        }
        RIME_STRUCT(RimeCommit, commit);
        check(api->get_commit(session, &commit), "selection did not submit");
        const std::string corrected = commit.text ? commit.text : "";
        api->free_commit(&commit);
        const std::string expected = target + (continuation ? "我们" : "") +
            (comma ? "，" : period ? "。" : "");
        check(corrected == expected, "submitted wrong correction");

        type();
        check(learned(), "one manual correction did not promote real-model candidate");
        if (correction_level != "off") std::cout << "after_one_submit: " << menu_prefix() << std::endl;
        std::cout << test_case << " " << argv[4] << " level=" << correction_level
            << " first=" << first() << " target_index=" << position(target)
            << " baseline_index=" << position(baseline) << std::endl;

        // Normal acceptance of the learned top candidate must remain a normal
        // commit. The Lua unit regression separately asserts that this writes
        // no additional learning event.
        if (std::string(argv[4]) == "tap" || correction_level != "off")
            check(api->select_candidate(session, position(target)), "learned exact tap rejected");
        else
            check(api->process_key(session, ' ', 0), "learned top space rejected");
        RIME_STRUCT(RimeCommit, accepted);
        check(api->get_commit(session, &accepted), "learned top did not submit");
        const std::string acceptedText = accepted.text ? accepted.text : "";
        api->free_commit(&accepted);
        check(acceptedText == target, "learned top submitted wrong text");
        type();
        check(learned(), "normal learned exact choice changed ranking");
        api->destroy_session(session); session = 0;
        api->finalize(); api->initialize(&traits);
        start(); type();
        check(learned(), "learning did not survive engine restart");
        if (correction_level != "off") std::cout << "after_restart: " << menu_prefix() << std::endl;
        api->destroy_session(session); session = 0; api->finalize();
        std::cout << "real Rime learning and restart passed\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        if (session) api->destroy_session(session);
        if (api) api->finalize();
        return 1;
    }
}
