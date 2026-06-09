// lattice.c — emit the fusion payload for one pinyin:
//   TOP   = librime's best full sentence (the librime-alone answer)
//   SYL   = per-syllable candidate characters (the constrained choice set for the LLM)
#include <rime_api.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static RimeApi* R;

// keep only a single CJK hanzi (3-byte UTF-8 in U+4E00..U+9FFF) — drops latin/emoji/symbols
static int is_one_hanzi(const char* t) {
  if (strlen(t) != 3) return 0;
  unsigned char b = (unsigned char)t[0];
  return b >= 0xE4 && b <= 0xE9;
}

static void topN_for(RimeSessionId s, const char* input, int n) {
  R->set_input(s, input);
  RimeCandidateListIterator it; memset(&it, 0, sizeof it);
  if (R->candidate_list_begin(s, &it)) {
    int c = 0;
    while (R->candidate_list_next(&it)) {
      if (it.candidate.text && is_one_hanzi(it.candidate.text)) {
        printf("%s%s", c ? " " : "", it.candidate.text);
        if (++c >= n) break;
      }
      if (it.index > 40) break;
    }
    R->candidate_list_end(&it);
  }
  printf("\n");
}

int main(int argc, char** argv) {
  const char* pinyin = argv[1];
  R = rime_get_api();
  RIME_STRUCT(RimeTraits, t);
  t.shared_data_dir = "/Users/joyzhang14/Projects/My-Portrait/Tests/writing-capture-extract/rime/ice";
  t.user_data_dir   = "/Users/joyzhang14/Projects/My-Portrait/Tests/writing-capture-extract/rime/ice-cands";
  t.app_name = "rime.lattice"; t.min_log_level = 3;
  R->setup(&t); R->initialize(&t);
  if (R->start_maintenance(True)) R->join_maintenance_thread();
  RimeSessionId s = R->create_session();
  R->set_option(s, "emoji", False);  // drop emoji candidates (noise for fusion)

  // top full sentence + syllable segmentation from preedit
  R->set_input(s, pinyin);
  RIME_STRUCT(RimeContext, ctx);
  R->get_context(s, &ctx);
  const char* top = (ctx.menu.num_candidates > 0 && ctx.menu.candidates[0].text)
                      ? ctx.menu.candidates[0].text : "";
  char preedit[256] = {0};
  if (ctx.composition.preedit) snprintf(preedit, sizeof preedit, "%s", ctx.composition.preedit);
  printf("TOP %s\n", top);
  R->free_context(&ctx);

  // per-syllable candidate chars (split preedit on spaces)
  char* save = NULL;
  for (char* syl = strtok_r(preedit, " ", &save); syl; syl = strtok_r(NULL, " ", &save)) {
    printf("SYL %s: ", syl);
    topN_for(s, syl, 6);
  }

  R->destroy_session(s); R->finalize();
  return 0;
}
