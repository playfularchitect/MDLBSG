-- MDLBSG Decompressor -- stays open until you click Close.

on logLaunch(tag)
	try
		do shell script "mkdir -p ~/.mdlbsg && echo \"$(date '+%Y-%m-%d %H:%M:%S') " & tag & "\" >> ~/.mdlbsg/launch.log"
	end try
end logLaunch

-- The main window, shared by every launch path.
on showMainWindow()
	activate
	repeat
		try
			activate
			set theReply to display dialog "MDLBSG Decompressor" & return & return & "Select a .mdl archive to restore. The original file is saved to your chosen save folder; archives that contain a folder are restored as a folder." & return & return & "You can also drag .mdl files onto this app's icon." with title "MDLBSG Decompressor" buttons {"Quit", "Choose Archives"} default button "Choose Archives" with icon note
		on error errText number errNum
			my logLaunch("DIALOG FAILED err=" & errNum & " " & errText)
			exit repeat
		end try
		if button returned of theReply is "Quit" then exit repeat
		try
			activate
			set picked to (choose file with prompt "Choose .mdl archives to restore:" default location (path to downloads folder) with multiple selections allowed)
			set thePaths to {}
			repeat with pf in picked
				set end of thePaths to POSIX path of pf
			end repeat
			set theOutput to my handleFiles(thePaths)
			activate
			set fin to display dialog theOutput with title "MDLBSG Decompressor" buttons {"Save Folder...", "OK"} default button "OK" with icon note
			if button returned of fin is "Save Folder..." then my pickDestDialog()
		on error number -128
			-- user cancelled the file picker; loop back to the main window
		end try
	end repeat
end showMainWindow

-- Finder double-click / right-click Open: macOS sends 'run'.
on run
	my logLaunch("run-handler MDLBSG Decompressor")
	my showMainWindow()
	my logLaunch("run-handler-exited MDLBSG Decompressor")
end run

-- DOCK CLICK on an app macOS considers already running: it sends 'reopen', NOT 'run'.
-- With no handler for this, the app received the event and did nothing at all --
-- silently, with no error and no log line. That was the Dock bug.
on reopen
	my logLaunch("reopen-handler (dock click) MDLBSG Decompressor")
	my showMainWindow()
	my logLaunch("reopen-handler-exited MDLBSG Decompressor")
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

on handleFiles(thePaths)
	if not my resolveDest() then return "Cancelled."
	set outLines to {}
	set fileCount to (count of thePaths)
	set fileIndex to 0
	repeat with p in thePaths
		set fileIndex to fileIndex + 1
		set thisPath to p as text
		set shortName to my baseName(thisPath)
		try
			set h to (POSIX path of (path to home folder)) & ".mdlbsg/bin/mdlbsg_extract_handler.sh"
			set tag to (do shell script "echo $$-$RANDOM")
			set pf to "/tmp/mdlbsg_prog_" & tag
			set outf to pf & ".out"
			set donef to pf & ".done"
			-- run it detached so we can watch progress; do shell script would block
			set destArg to ""
			if my sessionDest is not "" then set destArg to " " & quoted form of my sessionDest
			do shell script "( bash " & quoted form of h & " " & quoted form of thisPath & " " & quoted form of pf & destArg & " > " & quoted form of outf & " 2>&1; touch " & quoted form of donef & " ) > /dev/null 2>&1 &"
			set startTime to (current date)

			set progress total steps to 100
			set progress completed steps to 0
			if fileCount > 1 then
				set progress description to "Decompressing " & shortName & " (" & fileIndex & " of " & fileCount & ")"
			else
				set progress description to "Decompressing " & shortName & "..."
			end if
			set progress additional description to "Starting..."

			repeat
				try
					do shell script "test -f " & quoted form of donef
					exit repeat
				end try
				try
					set raw to do shell script "cat " & quoted form of pf & " 2>/dev/null || true"
					if raw is not "" then
						set doneBytes to (word 1 of raw) as number
						set totBytes to (word 2 of raw) as number
						if totBytes > 0 then
							set pct to round ((doneBytes / totBytes) * 100)
							if pct > 100 then set pct to 100
							set progress completed steps to pct
							set elapsed to ((current date) - startTime)
							set line1 to (pct as text) & "% complete"
							set line2 to "Time passed: " & my fmtSecs(elapsed)
							if elapsed > 0 and doneBytes > 0 then
								set mbps to (doneBytes / 1048576) / elapsed
								set line2 to line2 & "   -   " & my oneDecimal(mbps) & " MB/s"
							end if
							if pct > 0 and elapsed > 1 then
								set remain to (elapsed * (100 - pct)) / pct
								set line2 to line2 & "   -   ETA: " & my fmtSecs(remain)
							else
								set line2 to line2 & "   -   ETA: estimating..."
							end if
							set progress additional description to line1 & "   -   " & line2
						end if
					end if
				end try
				delay 0.3
			end repeat

			set progress completed steps to 100
			set progress additional description to "Finishing up..."
			set r to do shell script "cat " & quoted form of outf & " 2>/dev/null"
			do shell script "rm -f " & quoted form of pf & " " & quoted form of outf & " " & quoted form of donef & " || true"
			if r starts with "SAVE_FAILED" then
				set choice to my askWhereToSave(r)
				if choice is "retry" then
					set r to my runOnce(thisPath, h)
				else
					set r to "Cancelled."
				end if
			end if
			set end of outLines to r
		on error errMsg
			set end of outLines to "Error: " & errMsg
		end try
	end repeat
	-- clear the bar before the finish dialog
	set progress total steps to 0
	set progress completed steps to 0
	set progress description to ""
	set progress additional description to ""
	set msg to ""
	repeat with i from 1 to (count of outLines)
		if i > 1 then set msg to msg & linefeed
		set msg to msg & (item i of outLines)
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

on baseName(aPath)
	set t to aPath
	if t ends with "/" then set t to text 1 thru -2 of t
	set n to (count of t)
	repeat with i from n to 1 by -1
		if (character i of t) is "/" then return text (i + 1) thru n of t
	end repeat
	return t
end baseName

-- Files dragged onto the icon, or a .mdl double-clicked. A Dock click can also
-- deliver this event with an EMPTY list -- which used to show an empty dialog.
on open theFiles
	my logLaunch("open-handler MDLBSG Decompressor (" & (count of theFiles) & " files)")
	if (count of theFiles) is 0 then
		my showMainWindow()
		return
	end if
	set thePaths to {}
	repeat with f in theFiles
		set end of thePaths to POSIX path of f
	end repeat
	set theOutput to my handleFiles(thePaths)
	activate
	set fin to display dialog theOutput with title "MDLBSG Decompressor" buttons {"Save Folder...", "OK"} default button "OK" with icon note
			if button returned of fin is "Save Folder..." then my pickDestDialog()
end open
