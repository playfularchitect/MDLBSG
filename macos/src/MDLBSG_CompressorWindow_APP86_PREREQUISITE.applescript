-- MDLBSG Compressor
-- MDLBSG_RESULTS_DIALOG_V80_INSTALL_PROOF
-- MDLBSG_RESULTS_DETACH_PROGRESS_FIX_2026_07_21
-- MDLBSG_TRANSIENT_UI_V81_FIX
-- MDLBSG_TRUE_DETACH_V82_FIX
-- MDLBSG_FRESH_PROGRESS_WRAPPER_V85
-- MDLBSG_REENTRANT_DISPATCHER_V86
use AppleScript version "2.4"
use scripting additions
use framework "Foundation"
use framework "AppKit"
property mdlbsgCompiledProofMarker : "MDLBSG_RESULTS_DIALOG_V80_INSTALL_PROOF"
property mdlbsgTransientUIProofMarker : "MDLBSG_TRANSIENT_UI_V81"
property mdlbsgTrueDetachProofMarker : "MDLBSG_TRUE_DETACH_V82"
property mdlbsgFreshProgressWrapperMarker : "MDLBSG_FRESH_PROGRESS_WRAPPER_V85"
property mdlbsgReentrantDispatcherMarker : "MDLBSG_REENTRANT_DISPATCHER_V86"

on logLaunch(tag)
	try
		do shell script "mkdir -p ~/.mdlbsg && echo \"$(date '+%Y-%m-%d %H:%M:%S') " & tag & "\" >> ~/.mdlbsg/launch.log"
	end try
end logLaunch

-- The compression mode lives in one file shared with the command line, so the app and
-- the terminal can never disagree about which mode is active.
on currentMode()
	try
		set m to do shell script "cat ~/.mdlbsg/preset 2>/dev/null | tr -d '[:space:]'"
		if m is "fast" or m is "turbo" or m is "max" then return m
	end try
	return "turbo"
end currentMode

on modeDetail(m)
	if m is "fast" then return "Fastest - Fastest Speed, Least Compression"
	if m is "turbo" then return "Turbo V1 - Best Speed/Compression Ratio"
	return "Max Mode - Best Compression, Slowest Speed"
end modeDetail

on changeMode()
	set cur to my currentMode()
	set opts to {"Fastest - Fastest Speed, Least Compression", "Turbo V1 - Best Speed/Compression Ratio", "Max Mode - Best Compression, Slowest Speed"}
	set def to item 2 of opts
	if cur is "fast" then set def to item 1 of opts
	if cur is "max" then set def to item 3 of opts
	activate
	set chosen to (choose from list opts with prompt "Compression mode:" default items {def} with title "MDLBSG Compressor" OK button name "Use This Mode")
	if chosen is false then return
	set c to item 1 of chosen
	if c starts with "Fastest" then
		set m to "fast"
	else if c starts with "Turbo" then
		set m to "turbo"
	else
		set m to "max"
	end if
	try
		do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of m & " > ~/.mdlbsg/preset"
	end try
end changeMode


-- macOS's own alert panel. AppleScript's display dialog caps out at 3 buttons; this
-- has no limit, so Files and Folder can each get their own button. Returns the chosen
-- action, or "unavailable" if the panel can't be used -- in which case the caller falls
-- back to the 3-button dialog, so the app keeps working either way.
on mainMenu(modeLine)
	try
		set alert to current application's NSAlert's alloc()'s init()
		alert's setMessageText:"MDLBSG Compressor"
		alert's setInformativeText:(modeLine & return & return & "Files and folders are compressed to a .mdl archive and saved to your Downloads folder. Folders are compressed as a single unit." & return & return & "You can also drag files or folders onto this app's icon.")
		alert's setAlertStyle:1
		-- first added becomes the rightmost, default button
		alert's addButtonWithTitle:"Choose Files"
		alert's addButtonWithTitle:"Choose Folder"
		alert's addButtonWithTitle:"Change Mode"
		alert's addButtonWithTitle:"Quit"
		set answer to (alert's runModal()) as integer
		if answer is 1000 then return "files"
		if answer is 1001 then return "folder"
		if answer is 1002 then return "mode"
		return "quit"
	on error
		return "unavailable"
	end try
end mainMenu

-- Used only if the alert panel is unavailable.
on mainMenuFallback(modeLine)
	try
		set theReply to display dialog "MDLBSG Compressor" & return & return & modeLine & return & return & "Files and folders are compressed to a .mdl archive and saved to your Downloads folder." with title "MDLBSG Compressor" buttons {"Quit", "Change Mode", "Choose Items"} default button "Choose Items" with icon note
	on error number -128
		return "quit"
	end try
	set b to button returned of theReply
	if b is "Quit" then return "quit"
	if b is "Change Mode" then return "mode"
	try
		set pick to display dialog "Compress files, or an entire folder?" with title "MDLBSG Compressor" buttons {"Cancel", "A Folder", "Files"} default button "Files" with icon note
		if button returned of pick is "A Folder" then return "folder"
		return "files"
	on error number -128
		return "none"
	end try
end mainMenuFallback

on pickFiles()
	set picked to (choose file with prompt "Choose files to compress:" default location (path to downloads folder) with multiple selections allowed)
	set out to {}
	repeat with pf in picked
		set end of out to POSIX path of pf
	end repeat
	return out
end pickFiles

on pickFolder()
	return {POSIX path of (choose folder with prompt "Choose a folder to compress:" default location (path to downloads folder))}
end pickFolder

on showMainWindow()
	activate
	repeat
		set m to my currentMode()
		set modeLine to "MDLBSG is currently set to: " & my modeDetail(m)
		activate
		set act to my mainMenu(modeLine)
		if act is "unavailable" then set act to my mainMenuFallback(modeLine)
		if act is "quit" then exit repeat
		if act is "mode" then
			my changeMode()
		else if act is "files" or act is "folder" then
			try
				activate
				if act is "folder" then
					set thePaths to my pickFolder()
				else
					set thePaths to my pickFiles()
				end if
				if (count of thePaths) > 0 then
					set theOutput to my handleFiles(thePaths)
					activate
					set fin to my showResults(theOutput, (count of thePaths))
			if button returned of fin is "Save Folder..." then my pickDestDialog()
				end if
			on error number -128
				-- cancelled; back to the main window
			end try
		end if
	end repeat
end showMainWindow

-- The Compressor app itself must never own a modal menu. A modal menu keeps this
-- app process alive, which keeps the progress window alive and queues later drops.
-- The menu therefore runs in a separate osascript process. A real file drop kills
-- that helper before it can appear and is handled immediately by this app.
on closeMenuHelper()
	set killPattern to "^/usr/bin/osascript .*[/]launcher_dialog[.]applescript"
	try
		do shell script "/usr/bin/pkill -f " & quoted form of killPattern & " >/dev/null 2>&1 || true"
	end try
end closeMenuHelper

on launchMenuHelper()
	my closeMenuHelper()
	set helperPath to (POSIX path of (path to home folder)) & ".mdlbsg/launcher_dialog.applescript"
	set helperLog to (POSIX path of (path to home folder)) & ".mdlbsg/launcher_dialog_errors.log"
	try
		do shell script "test -f " & quoted form of helperPath
		do shell script "/usr/bin/nohup /usr/bin/osascript " & quoted form of helperPath & " </dev/null >/dev/null 2>>" & quoted form of helperLog & " &"
	on error errMsg number errNum
		my logLaunch("menu-helper-error " & (errNum as text) & " " & errMsg)
	end try
end launchMenuHelper

on run
	my logLaunch("run-handler MDLBSG Compressor -> detached menu helper")
	my launchMenuHelper()
end run

on reopen
	my logLaunch("reopen-handler MDLBSG Compressor -> detached menu helper")
	my launchMenuHelper()
end reopen


-- Where output goes for the rest of this session ("" = the saved default).
property sessionDest : ""

-- ============ SAVE-LOCATION "CHECKBOX" ============
-- State lives in ~/.mdlbsg/destdir:
--   file exists = box CHECKED   -> always save there, never ask
--   file absent = box UNCHECKED -> folder picker appears on every run
-- Every results window has a "Save Folder..." button to change or uncheck.
on resolveDest()
	set saved to ""
	try
		set saved to do shell script "cat ~/.mdlbsg/destdir 2>/dev/null"
	end try
	if saved is not "" then
		set my sessionDest to saved
		return true
	end if
	return my pickDestDialog()
end resolveDest

-- Folder picker + the remember question. Two buttons emulate the checkbox:
-- "Always Save Here" checks it (writes destdir); "Just This Once" leaves it
-- unchecked, so the picker returns next run.
on pickDestDialog()
	activate
	try
		set f to POSIX path of (choose folder with prompt "Where should MDLBSG save its output?" default location (path to downloads folder))
	on error number -128
		return false
	end try
	set my sessionDest to f
	try
		activate
		set dlg to display dialog "Save to this folder every time?" & return & return & f & return & return & "(Change it anytime -- every results window has a Save Folder... button.)" with title "Save Location" buttons {"Just This Once", "Always Save Here"} default button "Always Save Here" with icon note
		if button returned of dlg is "Always Save Here" then
			do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of f & " > ~/.mdlbsg/destdir"
		else
			do shell script "rm -f ~/.mdlbsg/destdir"
		end if
	on error number -128
		return false
	end try
	return true
end pickDestDialog


-- macOS only lets an app write where the USER has pointed it. So when a save is
-- blocked, the honest fix is to let you choose the folder -- picking it IS the
-- permission grant, as far as the system is concerned.
on askWhereToSave(reasonText)
	activate
	-- A full disk is not a permissions problem: every folder on this Mac shares
	-- the same disk, so offering the folder picker as the fix would be a lie.
	-- Say what is actually wrong and what actually helps.
	if reasonText contains "No space left on device" then
		set msgText to "Your disk is FULL -- that is why the save failed." & return & return & reasonText & return & return & "Picking another folder on this Mac will not help; they all share the same disk. Free up space (Apple menu > System Settings > General > Storage), or choose a folder on an external drive / USB stick."
	else
		set msgText to "MDLBSG could not save to that folder." & return & return & reasonText & return & return & "macOS grants access to folders you choose yourself. Pick a destination to continue."
	end if
	try
		set dlg to display dialog msgText with title "Choose a Destination" buttons {"Quit", "Just This Once", "Always Save Here"} default button "Always Save Here" with icon caution
	on error number -128
		return "cancel"
	end try
	set b to button returned of dlg
	if b is "Quit" then return "cancel"
	try
		set f to POSIX path of (choose folder with prompt "Choose where MDLBSG should save its output:")
	on error number -128
		return "cancel"
	end try
	set my sessionDest to f
	if b is "Always Save Here" then
		try
			do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of f & " > ~/.mdlbsg/destdir"
		end try
	end if
	return "retry"
end askWhereToSave

-- Re-run one item into the chosen destination (no bar; this path is the exception).
on runOnce(thisPath, h)
	set tag2 to (do shell script "echo $$-$RANDOM-r")
	set of2 to "/tmp/mdlbsg_retry_" & tag2
	try
		do shell script "bash " & quoted form of h & " " & quoted form of thisPath & " '' " & quoted form of my sessionDest & " > " & quoted form of of2 & " 2>&1"
	end try
	set out2 to do shell script "cat " & quoted form of of2 & " 2>/dev/null"
	do shell script "rm -f " & quoted form of of2 & " || true"
	return out2
end runOnce

on writeFreshProgressState(statePath, pctValue, titleText, detailText)
	set tmpPath to statePath & ".tmp"
	set cmd to "/usr/bin/printf '%s\n%s\n%s\n' " & quoted form of (pctValue as text) & " " & quoted form of (titleText as text) & " " & quoted form of (detailText as text) & " > " & quoted form of tmpPath & " && /bin/mv -f " & quoted form of tmpPath & " " & quoted form of statePath
	do shell script cmd
end writeFreshProgressState

on startFreshProgressWindow(statePath, cancelPath, closedPath, readyPath)
	set homePath to POSIX path of (path to home folder)
	set helperPath to homePath & ".mdlbsg/bin/mdlbsg_progress_window"
	set detachedLauncher to homePath & ".mdlbsg/bin/mdlbsg_detached_spawn"

	do shell script "test -x " & quoted form of helperPath & " && test -x " & quoted form of detachedLauncher
	do shell script "/bin/rm -f " & quoted form of statePath & " " & quoted form of cancelPath & " " & quoted form of closedPath & " " & quoted form of readyPath & " " & quoted form of (statePath & ".tmp")

	my writeFreshProgressState(statePath, 0, "Preparing MDLBSG compression", "Preparing...")

	set launchCommand to quoted form of detachedLauncher & " " & quoted form of helperPath & " --state " & quoted form of statePath & " --cancel " & quoted form of cancelPath & " --closed " & quoted form of closedPath & " --ready " & quoted form of readyPath

	do shell script launchCommand

	repeat with readyIndex from 1 to 80
		try
			do shell script "test -f " & quoted form of readyPath
			return true
		end try

		delay 0.05
	end repeat

	error "The fresh progress window did not become ready."
end startFreshProgressWindow

on closeFreshProgressWindow(statePath, cancelPath, closedPath, readyPath)
	try
		set closeTmp to statePath & ".closing"
		do shell script "/usr/bin/printf 'CLOSE\n' > " & quoted form of closeTmp & " && /bin/mv -f " & quoted form of closeTmp & " " & quoted form of statePath
	end try

	repeat with closeIndex from 1 to 80
		try
			do shell script "test -f " & quoted form of closedPath
			exit repeat
		end try

		delay 0.05
	end repeat

	try
		do shell script "/bin/rm -f " & quoted form of statePath & " " & quoted form of cancelPath & " " & quoted form of closedPath & " " & quoted form of readyPath & " " & quoted form of (statePath & ".tmp") & " " & quoted form of (statePath & ".closing")
	end try
end closeFreshProgressWindow

on cancelFreshJob(pidPath)
	try
		set jobPID to (do shell script "cat " & quoted form of pidPath & " 2>/dev/null") as integer

		if jobPID > 1 then
			do shell script "/bin/kill -TERM -" & (jobPID as text) & " 2>/dev/null || true; /bin/sleep 0.3; /bin/kill -KILL -" & (jobPID as text) & " 2>/dev/null || true"
		end if
	end try
end cancelFreshJob

on handleFiles(thePaths)
	if not my resolveDest() then return "Cancelled."

	set outLines to {}
	set fileCount to count of thePaths
	set fileIndex to 0
	set cancelAll to false

	set sessionTag to do shell script "echo $$-$RANDOM-$RANDOM"
	set statePath to "/tmp/mdlbsg_ui_" & sessionTag
	set cancelPath to statePath & ".cancel"
	set closedPath to statePath & ".closed"
	set readyPath to statePath & ".ready"

	try
		my startFreshProgressWindow(statePath, cancelPath, closedPath, readyPath)
	on error errMsg
		return "Error: " & errMsg
	end try

	repeat with p in thePaths
		set fileIndex to fileIndex + 1
		set thisPath to p as text
		set shortName to my baseName(thisPath)

		if fileCount > 1 then
			set progressTitle to "Compressing " & shortName & " (" & fileIndex & " of " & fileCount & ")"
		else
			set progressTitle to "Compressing " & shortName
		end if

		try
			my writeFreshProgressState(statePath, 0, progressTitle, "Preparing...")

			set h to (POSIX path of (path to home folder)) & ".mdlbsg/bin/mdlbsg_droplet_handler.sh"
			set tag to sessionTag & "-" & fileIndex

			set pf to "/tmp/mdlbsg_prog_" & tag
			set outf to pf & ".out"
			set donef to pf & ".done"
			set pidf to pf & ".pid"
			set statusf to pf & ".status"
			set destPath to my sessionDest

			set pythonCode to "import os,sys; os.setsid(); os.execv('/bin/bash', ['/bin/bash'] + sys.argv[1:])"

			set launchCmd to "( /usr/bin/python3 -c " & quoted form of pythonCode & " " & quoted form of h & " " & quoted form of thisPath & " " & quoted form of pf & " " & quoted form of destPath & " > " & quoted form of outf & " 2>&1 & jobpid=$!; /usr/bin/printf '%s' \"$jobpid\" > " & quoted form of pidf & "; wait \"$jobpid\"; /usr/bin/printf '%s' \"$?\" > " & quoted form of statusf & "; /usr/bin/touch " & quoted form of donef & " ) >/dev/null 2>&1 &"

			do shell script launchCmd

			set startTime to current date
			set encodeStart to missing value
			set wasCancelled to false

			repeat
				try
					do shell script "test -f " & quoted form of donef
					exit repeat
				end try

				try
					do shell script "test -f " & quoted form of cancelPath

					set wasCancelled to true
					my writeFreshProgressState(statePath, 0, progressTitle, "Stopping...")
					my cancelFreshJob(pidf)

					repeat with stopWait from 1 to 40
						try
							do shell script "test -f " & quoted form of donef
							exit repeat
						end try

						delay 0.1
					end repeat

					exit repeat
				end try

				try
					set raw to do shell script "cat " & quoted form of pf & " 2>/dev/null || true"

					if raw is "" then
						set elapsed to current date - startTime
						set prepLine to "Preparing... " & my fmtSecs(elapsed)

						if elapsed > 5 then
							set prepLine to prepLine & "   -   Large files/folders 1 GB or more may take around 30 seconds or more to begin compression!"
						end if

						my writeFreshProgressState(statePath, 0, progressTitle, prepLine)
					else
						set doneBytes to (word 1 of raw) as number
						set totBytes to (word 2 of raw) as number

						if totBytes > 0 then
							if encodeStart is missing value then set encodeStart to current date

							set pct to round ((doneBytes / totBytes) * 100)

							if pct > 100 then set pct to 100
							if pct < 0 then set pct to 0

							set elapsed to current date - startTime
							set encElapsed to current date - encodeStart

							set line1 to (pct as text) & "% complete   -   " & my oneDecimal(doneBytes / 1000000) & " of " & my oneDecimal(totBytes / 1000000) & " MB"
							set line2 to "Time passed: " & my fmtSecs(elapsed)

							if encElapsed > 0 and doneBytes > 0 then
								set mbps to (doneBytes / 1000000) / encElapsed
								set line2 to line2 & "   -   " & my oneDecimal(mbps) & " MB/s"
							end if

							if pct > 0 and encElapsed > 1 then
								set remain to (encElapsed * (100 - pct)) / pct
								set line2 to line2 & "   -   ETA: " & my fmtSecs(remain)
							else
								set line2 to line2 & "   -   ETA: estimating..."
							end if

							my writeFreshProgressState(statePath, pct, progressTitle, line1 & "   -   " & line2)
						end if
					end if
				end try

				delay 0.25
			end repeat

			if wasCancelled then
				set r to "Cancelled."
				set cancelAll to true
			else
				my writeFreshProgressState(statePath, 100, progressTitle, "Finishing...")

				set r to do shell script "cat " & quoted form of outf & " 2>/dev/null"

				if r starts with "SAVE_FAILED" then
					my writeFreshProgressState(statePath, 100, progressTitle, "Waiting for a save location...")

					set choice to my askWhereToSave(r)

					if choice is "retry" then
						set r to my runOnce(thisPath, h)
					else
						set r to "Cancelled."
					end if
				end if
			end if

			try
				do shell script "/bin/rm -f " & quoted form of pf & " " & quoted form of outf & " " & quoted form of donef & " " & quoted form of pidf & " " & quoted form of statusf
			end try

			set end of outLines to r
		on error errMsg
			set end of outLines to "Error: " & errMsg
		end try

		if cancelAll then exit repeat
	end repeat

	try
		my writeFreshProgressState(statePath, 100, "MDLBSG Compressor", "Closing progress window...")
		delay 0.1
	end try

	my closeFreshProgressWindow(statePath, cancelPath, closedPath, readyPath)

	set msg to ""

	repeat with i from 1 to count of outLines
		if i > 1 then set msg to msg & linefeed
		set msg to msg & item i of outLines
	end repeat

	return msg
end handleFiles

on fmtSecs(s)
	set s to s as integer
	if s < 60 then return (s as text) & "s"
	if s < 3600 then return ((s div 60) as text) & "m " & ((s mod 60) as text) & "s"
	return ((s div 3600) as text) & "h " & (((s mod 3600) div 60) as text) & "m"
end fmtSecs

on oneDecimal(x)
	set r to (round (x * 10)) / 10
	return r as text
end oneDecimal

on showResults(theOutput, itemCount)
	-- App 82 uses a tiny native double-fork launcher. The launcher exits at once,
	-- while the independent osascript process owns the results dialog. This avoids
	-- the shell-background process remaining attached to AppleScript's do shell
	-- script call and keeping this Compressor instance alive.
	set tmpF to ""
	set fh to missing value
	try
		set tmpF to do shell script "/usr/bin/mktemp -t mdlbsg_res"
		set fh to open for access POSIX file tmpF with write permission
		set eof of fh to 0
		write theOutput to fh as «class utf8»
		close access fh
		set fh to missing value
		set homePath to POSIX path of (path to home folder)
		set dlgScript to homePath & ".mdlbsg/results_dialog.applescript"
		set detachedLauncher to homePath & ".mdlbsg/bin/mdlbsg_detached_spawn"
		do shell script "test -x " & quoted form of detachedLauncher & " && test -f " & quoted form of dlgScript
		do shell script quoted form of detachedLauncher & " /usr/bin/osascript " & quoted form of dlgScript & " " & quoted form of tmpF
		my logLaunch("results-helper detached " & tmpF)
		return true
	on error errMsg number errNum
		try
			if fh is not missing value then close access fh
		end try
		try
			set logPath to (POSIX path of (path to home folder)) & ".mdlbsg/results_dialog_errors.log"
			set logHandle to open for access POSIX file logPath with write permission
			write (((current date) as text) & " | error " & (errNum as text) & " | " & errMsg & linefeed) to logHandle starting at eof
			close access logHandle
		end try
		-- Preserve the result even if the detached launcher itself fails. This is
		-- intentionally blocking only as an emergency fallback, and the exact error
		-- is recorded above.
		set fallbackDialog to display dialog theOutput with title "MDLBSG Compressor" buttons {"Save Folder...", "OK"} default button "OK" with icon note
		if button returned of fallbackDialog is "Save Folder..." then my pickDestDialog()
		return false
	end try
end showResults

on baseName(aPath)
	set t to aPath
	if t ends with "/" then set t to text 1 thru -2 of t
	set n to (count of t)
	repeat with i from n to 1 by -1
		if (character i of t) is "/" then return text (i + 1) thru n of t
	end repeat
	return t
end baseName


-- A newly dropped item replaces the old completed-results popup.
-- It does not kill the compressor core or an active compression job.
on closePreviousResultsPopup()
	set killPattern to "^/usr/bin/osascript .*[/]results_dialog[.]applescript"

	try
		do shell script "/usr/bin/pkill -TERM -f " & quoted form of killPattern & " >/dev/null 2>&1 || true; /bin/sleep 0.15; /usr/bin/pkill -KILL -f " & quoted form of killPattern & " >/dev/null 2>&1 || true"
	end try
end closePreviousResultsPopup

on dispatchFreshWorker(thePaths)
	-- New rule: the previous completed stats popup disappears
	-- immediately when a new compression is dropped.
	my closePreviousResultsPopup()

	if not my resolveDest() then return false

	set homePath to POSIX path of (path to home folder)
	set detachedLauncher to homePath & ".mdlbsg/bin/mdlbsg_detached_spawn"
	set workerPath to homePath & ".mdlbsg/bin/mdlbsg_ui_worker.py"

	do shell script "test -x " & quoted form of detachedLauncher & " && test -x " & quoted form of workerPath

	set launchCommand to quoted form of detachedLauncher & " /usr/bin/python3 " & quoted form of workerPath & " --dest " & quoted form of my sessionDest & " --"

	repeat with currentPath in thePaths
		set launchCommand to launchCommand & " " & quoted form of (currentPath as text)
	end repeat

	do shell script launchCommand

	my logLaunch("app86 independent worker dispatched (" & (count of thePaths) & " items)")

	return true
end dispatchFreshWorker

on open theFiles
	my logLaunch("app86 open-handler (" & (count of theFiles) & " items)")
	my closeMenuHelper()

	if (count of theFiles) is 0 then
		my launchMenuHelper()
		return
	end if

	set thePaths to {}

	repeat with currentFile in theFiles
		set end of thePaths to POSIX path of currentFile
	end repeat

	try
		set dispatched to my dispatchFreshWorker(thePaths)

		if not dispatched then
			my logLaunch("app86 dispatch cancelled")
		end if
	on error errMsg number errNum
		my logLaunch("app86 dispatch ERROR " & (errNum as text) & " " & errMsg)

		activate

		display dialog "MDLBSG could not start the new compression job." & return & return & errMsg with title "MDLBSG Compressor" buttons {"OK"} default button "OK" with icon caution
	end try

	-- The worker now owns this job. The app exits immediately so the
	-- next drag always launches a fresh dispatcher process.
	quit
end open
