// cands.c — dump librime 对一个拼音的 top-N 候选(LLM 重建时的"合法搜索空间")。
// 数据目录走环境变量 RIME_SHARED / RIME_USER(便携,不硬编码 /tmp)。
// 编译:见 build.sh;依赖 homebrew librime。输出每行 "[idx]\t候选"。
#include <rime_api.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: cands <pinyin> [N]\n"); return 2; }
  const char* pinyin = argv[1];
  int N = argc > 2 ? atoi(argv[2]) : 15;
  const char* shared = getenv("RIME_SHARED"); if (!shared) shared = "ice";
  const char* user   = getenv("RIME_USER");   if (!user)   user   = "ice-cands";

  RimeApi* R = rime_get_api();
  RIME_STRUCT(RimeTraits, t);
  t.shared_data_dir = shared;
  t.user_data_dir   = user;
  t.app_name = "rime.cands";
  t.min_log_level = 3;
  R->setup(&t);
  R->initialize(&t);
  if (R->start_maintenance(True)) R->join_maintenance_thread();

  RimeSessionId s = R->create_session();
  R->set_input(s, pinyin);
  printf("== %s ==\n", pinyin);
  RimeCandidateListIterator it; memset(&it, 0, sizeof it);
  if (R->candidate_list_begin(s, &it)) {
    while (R->candidate_list_next(&it)) {
      printf("[%d]\t%s\n", it.index, it.candidate.text ? it.candidate.text : "");
      if (it.index >= N - 1) break;
    }
    R->candidate_list_end(&it);
  }
  R->destroy_session(s);
  R->finalize();
  return 0;
}
