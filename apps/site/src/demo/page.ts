// the page's one script: it finds the two demos and hands each to its view.

import { mountDictation } from "./dictation-view";
import { mountMeeting } from "./meeting-view";

const dictation = document.querySelector<HTMLElement>("[data-demo]");
if (dictation) mountDictation(dictation);

const meeting = document.querySelector<HTMLElement>("[data-meeting]");
if (meeting) mountMeeting(meeting);
