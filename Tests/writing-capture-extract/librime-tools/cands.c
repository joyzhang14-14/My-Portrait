// cands.c — dump librime's top-N candidates for a pinyin (the "search space" an LLM would pick from)
#include <rime_api.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, char** argv) {
  const char* pinyin = argv[1];
  int N = argc > 2 ? atoi(argv[2]) : 15;
  RimeApi* R = rime_get_api();
  RIME_STRUCT(RimeTraits, t);
  t.shared_data_dir = "/tmp/rime-test/ice";
  t.user_data_dir   = "/tmp/rime-test/ice-cands";
  t.app_name = "rime.cands"; t.min_log_level = 3;
  R->setup(&t); R->initialize(&t);
  if (R->start_maintenance(True)) R->join_maintenance_thread();
  RimeSessionId s = R->create_session();
  R->set_input(s, pinyin);
  printf("== %s ==\n", pinyin);
  RimeCandidateListIterator it; memset(&it, 0, sizeof it);
  if (R->candidate_list_begin(s, &it)) {
    while (R->candidate_list_next(&it)) {
      printf("  [%d] %s\n", it.index, it.candidate.text ? it.candidate.text : "");
      if (it.index >= N - 1) break;
    }
    R->candidate_list_end(&it);
  }
  R->destroy_session(s); R->finalize();
  return 0;
}
