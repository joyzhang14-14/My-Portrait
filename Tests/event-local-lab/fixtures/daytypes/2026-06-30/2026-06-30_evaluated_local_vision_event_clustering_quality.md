---
created: 2026-06-30
impact: 3.7
raw_impact: 3.7
rebalance_count: 0
impact_source: llm:gpt-5.4
weight: 4.506
occurrences: [2026-06-30]
event_title: "Evaluated local-vision event clustering quality"
event_summary: "The user compared a new event-localization pipeline that feeds local-vision session digests into gpt-5.4 against the production OCR-based clustering pipeline. They concluded that the local-vision path produced 41 events versus production's 28 while still preserving concrete details such as Wang Yu referral math, AudioError, RECENTS, videoFps, and Power Mode Balanced. The OCR shows them noting two caveats: some digests with names like 王昱 and He Cheng were sent upstream without redaction, and a few V4 titles were slightly off, including a screenshot-OCR-to-Swift event that may have cropped the RECENTS sidebar too narrowly. They also sampled summary quality using specifics like WritingCaptureWorker.swift, commit 6143423, referral URLs, and silero_vad.onnx, then tried to write an Obsidian comparison archive of the 41-vs-28 results."
type: experience
member_frame_ids: [200313, 200314, 200315, 200316, 200330, 200331, 200332, 200333, 200334, 200335, 200336, 200337, 200338, 200339, 200340, 200341, 200342, 200343, 200344, 200345, 200346, 200347, 200348, 200349, 200350, 200351, 200352, 200353, 200354, 200355, 200356, 200357, 200358, 200359, 200360, 200361, 200362, 200363, 200364, 200365, 200366, 200367, 200368, 200369, 200370, 200371, 200372, 200373, 200374, 200375, 200376, 200377, 200378, 200379, 200380, 200381, 200382, 200383, 200384, 200385, 200386, 200387, 200388, 200400, 200401, 200402, 200403, 200404, 200405, 200406, 200407, 200408, 200409, 200410, 200411, 200412, 200413, 200414, 200415, 200416, 200417, 200418, 200419, 200420, 200421, 200422, 200423, 200424, 200425, 200426, 200427, 200428, 200429, 200430, 200431, 200432, 200433, 200434, 200435, 200874, 200974, 201338, 201359, 202794, 202858, 202859, 202860, 202870, 202871, 202872, 202873]
distilled_into: [experiences/building_my_portrait_ai_memory_system]
source: "timeline:event"
tags: [my-portrait, event-clustering, local-vision, ocr, gpt-5.4, evaluation]
superseded_by: null
pinned: false
archived_at: null
---
# Evaluated local-vision event clustering quality

The user compared a new event-localization pipeline that feeds local-vision session digests into gpt-5.4 against the production OCR-based clustering pipeline. They concluded that the local-vision path produced 41 events versus production's 28 while still preserving concrete details such as Wang Yu referral math, AudioError, RECENTS, videoFps, and Power Mode Balanced. The OCR shows them noting two caveats: some digests with names like 王昱 and He Cheng were sent upstream without redaction, and a few V4 titles were slightly off, including a screenshot-OCR-to-Swift event that may have cropped the RECENTS sidebar too narrowly. They also sampled summary quality using specifics like WritingCaptureWorker.swift, commit 6143423, referral URLs, and silero_vad.onnx, then tried to write an Obsidian comparison archive of the 41-vs-28 results.
