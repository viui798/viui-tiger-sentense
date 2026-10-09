// Real librime radio selection and persistent level migration, isolated data.
#include <rime_api.h>
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
static RimeApi* api=nullptr;
static unsigned checks=0;
static const std::vector<std::string> levels={"off","weak","medium","strong"};
static void check(bool ok,const std::string& msg){++checks;if(!ok)throw std::runtime_error(msg);}
static std::string option(const std::string& level){return "tiger_sentence_correction_"+level;}
static std::string property(RimeSessionId s,const char* name){char value[8192]={};api->get_property(s,name,value,sizeof(value));return value;}
static std::string input(RimeSessionId s){const char* p=api->get_input(s);return p?p:"";}
static std::string drain(RimeSessionId s){RIME_STRUCT(RimeCommit,c);std::string v;if(api->get_commit(s,&c)){v=c.text?c.text:"";api->free_commit(&c);}return v;}
static void expect(RimeSessionId s,const std::string& level){
 for(const auto& v:levels)check(!!api->get_option(s,option(v).c_str())==(v==level),"radio mismatch: "+v+" expected "+level);
 check(!!api->get_option(s,"tiger_sentence_key_correction")== (level!="off"),"legacy enabled flag mismatch");
 check(property(s,"tiger_sentence_correction_level")==level,"reported level mismatch");
}
static std::string first(RimeSessionId s){RIME_STRUCT(RimeContext,c);check(api->get_context(s,&c),"missing context");std::string v=c.menu.num_candidates>0?c.menu.candidates[0].text:"";int corrections=0;
 for(int i=0;i<c.menu.num_candidates;++i){
  const std::string comment=c.menu.candidates[i].comment?c.menu.candidates[i].comment:"";
  check(comment.empty()||comment==u8"\U0001F41E","candidate comment is not one ladybug");
  if(!comment.empty())++corrections;
 }
 api->free_context(&c);check(corrections<=2,"menu correction cap exceeded");return v;}
static void choose(RimeSessionId s,const std::string& level,bool clear_first=false){
 if(clear_first)for(const auto& v:levels)if(v!=level)api->set_option(s,option(v).c_str(),False);
 api->set_option(s,option(level).c_str(),True);expect(s,level);
}
int main(int argc,char**argv){
 std::vector<RimeSessionId> sessions;
 try{
  check(argc==6,"user shared plugin mode expected-level");api=rime_get_api();
  check(dlopen(argv[3],RTLD_NOW|RTLD_GLOBAL)!=nullptr,"lua plugin unavailable");
  const char* modules[]={"default","lua",nullptr};RIME_STRUCT(RimeTraits,t);
  t.user_data_dir=argv[1];t.shared_data_dir=argv[2];t.log_dir=argv[1];t.app_name="rime.tiger.levels";t.modules=modules;
  api->setup(&t);api->initialize(&t);if(api->start_maintenance(True))api->join_maintenance_thread();
  auto create=[&](){auto s=api->create_session();sessions.push_back(s);check(s&&api->select_schema(s,"tiger_sentence"),"cannot select schema");api->set_option(s,"ascii_mode",False);return s;};
  auto key=[&](RimeSessionId s,int code){api->process_key(s,code,0);};
  auto type=[&](RimeSessionId s,const std::string& text){for(unsigned char ch:text)key(s,ch);};
  auto reset=[&](RimeSessionId s){api->clear_composition(s);drain(s);};
  auto a=create();std::string mode=argv[4],expected=argv[5];expect(a,expected);
  if(mode=="read"){
   type(a,"ptue");expect(a,expected);first(a);reset(a);
  }else if(mode=="write"){
   auto b=create();expect(b,expected);
   for(const auto& level:levels){
    reset(a);choose(a,level);type(a,"ptue");expect(a,level);first(a);reset(a);
    type(b,"a");expect(b,level);reset(b);
   }
   // Switching ranking strength must not rewrite input or commit a selection.
   choose(a,"medium");type(a,"ptue");std::string raw=input(a);
   for(const auto& from:levels)for(const auto& to:levels){
    choose(a,from);choose(a,to,true);check(input(a)==raw&&drain(a).empty(),"level switch changed composition");first(a);
   }
   reset(a);choose(a,"strong");api->set_option(a,"tiger_sentence_key_correction",False);expect(a,"off");
   api->set_option(a,"tiger_sentence_key_correction",True);expect(a,"medium");
   choose(a,"weak");api->set_option(b,"tiger_sentence_early_commit",False);
   type(a,"a");expect(a,"weak");check(!api->get_option(a,"tiger_sentence_early_commit"),"stale session lost unrelated choice");reset(a);
   choose(b,"strong");type(a,"a");expect(a,"strong");reset(a);
   check(api->select_schema(a,"other")&&api->select_schema(a,"tiger_sentence"),"schema roundtrip failed");expect(a,"strong");
   auto c=create();expect(c,"strong");
  }else if(mode=="real"){
   for(const auto& level:std::vector<std::string>{"weak","medium","strong"})for(bool preedit:{false,true}){
    reset(a);choose(a,level);api->set_option(a,"tiger_sentence_early_commit",True);
    api->set_option(a,"tiger_sentence_early_commit_to_preedit",preedit?True:False);
    type(a,"ptu");check(input(a)=="ptu"&&drain(a).empty(),"enabled strength allowed empty-code commit");
    check(property(a,"tiger_sentence_buffered_text").empty(),"enabled strength locked empty-code result");
    key(a,'e');std::string top=first(a);check(top=="是的","enabled level failed ptue correction");
    check(property(a,"test_level_penalty")== (level=="weak"?"8":level=="medium"?"6":"4"),"runtime penalty mismatch");
    key(a,' ');check(drain(a)==top&&input(a).empty(),"manual confirmation failed");
   }
   reset(a);choose(a,"off");api->set_option(a,"tiger_sentence_early_commit_to_preedit",False);type(a,"ptu");
   check(drain(a)=="跃"&&input(a)=="u","off did not retain original empty-code behavior");
  }else check(mode=="defaults"||mode=="legacy","unknown probe mode");
  for(auto s:sessions)api->destroy_session(s);sessions.clear();api->finalize();
  std::cout<<"{\"level_host_checks\":"<<checks<<",\"mode\":\""<<mode<<"\",\"status\":\"passed\"}\n";return 0;
 }catch(const std::exception&e){std::cerr<<e.what()<<'\n';if(api){for(auto s:sessions)if(s)api->destroy_session(s);api->finalize();}return 1;}
}
