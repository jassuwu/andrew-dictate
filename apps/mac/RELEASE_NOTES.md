## 0.10.0

the trust release. two bugs made restarting the app the only fix. both are gone, along with everything shaped like them.

plugging in a monitor, closing the lid or waking the mac no longer leaves fn loading forever. the mic is reopened fresh after any change to your audio, displays or sleep, and nothing to do with audio runs where it can freeze the app.

airpods taken by a call no longer leave a lamp that pastes nothing. each press uses whatever mic your mac is on right now: airpods when they're connected, the built-in one when they're not. if the mic changes mid-sentence, what you said up to then is pasted.

only you throw a dictation away. `esc` still does. sleep, the lock and the five-minute cap end a dictation and keep it. the screen stays awake while the mic is on, and if it locks anyway, the text is on your clipboard when you come back.

the start sound and the lamp now mean the mic is hearing you, not just that you pressed a key. a mic that sends nothing says so by name, `no sound from airpods pro`, instead of pretending to listen. a speech model that stops answering gets restarted, and nothing waits forever.

the menu tells you when there's a new version, and clicking `update to …` runs brew for you. to know about one, the app asks dictate.jass.gg once a day, sending only the version you're running. i count those asks per version per day and keep nothing else. settings › general has the switch. if you're on 0.9.2, this is the last `brew upgrade` you'll have to type.

fix the same misheard word twice and it's learned. `learned: jass.gg` says so once, and one click takes it back.

`copy diagnostics` in the menu copies how your last fifty dictations ended. it has none of your words in it, and it's what to send me when something breaks.

and it's quicker. the speech model wakes up when you press, so it's ready when you let go.

## 0.9.4

the lamp. the gold line at the bottom of the screen is now a glass tube: a translucent body that takes the window behind it, a pale rim, a shade, a halo that spills when you speak. it waves to your voice and lights up with it, and it holds over a white page as well as a black one — the old line vanished on a document. a locked recording pins it with a bead at each end.

it is drawn by hand, not Liquid Glass, because Liquid Glass draws dimmed in any window that is not the key window, and the lamp's panel must never be key — it would take the keyboard from the app you are dictating into.

the pill that carries an exceptional sentence sits on the same invisible stage as the tube, so the window no longer changes shape around it.

the mic-toggle sound plays 8 db quieter. same switch, further from the ear.

## 0.9.3

the polish release. a hundred small things a switcher would have tripped on in week one, most of them found by reading the code against the wispr flow bar and then fixed one commit at a time.

the key: granting accessibility makes fn work without a relaunch, setup asks you to press your key before it lets you finish, and esc, the double-tap lock and the five-minute cap are written down under `key` in settings.

what lands: two dictations in a row get a space between them, a dictation into the middle of a sentence keeps its lowercase, "7 p. M." and "1. 5" are gone, and `one` stays a word. the settings tile measures to the keystroke now, not to the clipboard restore that ran after it.

failure has a voice: every `copied` pill ends in `⌘V to paste`, pills stay up long enough to read, a stray tap is silent instead of chiming twice and saying `heard nothing`, airpods arriving mid-sentence says so, and `try that again` in the menu re-runs a dictation the model dropped.

teach it a word: `fix a word…` points at what the model actually heard, the dictionary runs before the parsers so an entry always fires, importing asks before it replaces your words, and settings lists the words it keeps mishearing.

meetings: transcripts moved out of ~/Documents (icloud syncs it) into `~/andrew-dictate`, files are 0600, a saved meeting gets a notification with `show in finder`, a mac that slept mid-call writes a gap instead of `complete: true`, and quitting mid-meeting waits for the file.

updating is one command, and every surface says it: `brew upgrade --cask jassuwu/tap/andrew-dictate`. your gatekeeper approval and your microphone and accessibility grants come with you. about notices when the new version is already sitting in /Applications, and restarts onto it. a second copy of the app refuses to run.

the readme stops recommending right-click → open, which macOS removed two versions ago, and the site finally shows the thing working.

## 0.9.2

a release-build fix in the about window's credits. nothing you can feel changed.

## 0.9.1

the site and the readme carry both jobs, dictation and meetings, in the app's own voice. the pipeline lost a stage it had stopped using.

## 0.9.0

meetings. pick an app from the menu bar, talk, press stop, and get one markdown file with the speakers split out. your mic is you, the app you picked is them.

whisper large-v3 does the listening, on your mac. the live panel shows it arrive — confirmed in ink, the tail dimmed. no audio is kept once the file is written.

setup asks which job you want now — dictation, meetings, or both — and only asks macOS for what that job needs.
