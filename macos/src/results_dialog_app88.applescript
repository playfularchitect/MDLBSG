-- MDLBSG_RESULTS_COMPRESSOR_ICON_APP88
use AppleScript version "2.4"
use scripting additions

on run argv
	if (count of argv) < 1 then return

	set resultPath to item 1 of argv
	set resultText to ""

	try
		set resultText to read POSIX file resultPath as «class utf8»
	end try

	try
		do shell script "/bin/rm -f " & quoted form of resultPath
	end try

	if resultText is "" then return

	set compressorIcon to missing value

	try
		set iconPath to do shell script "cat ~/.mdlbsg/results_icon_path 2>/dev/null"

		if iconPath is not "" then
			set compressorIcon to (POSIX file iconPath) as alias
		end if
	end try

	activate

	if compressorIcon is missing value then
		set resultDialog to display dialog resultText with title "MDLBSG Compressor" buttons {"Save Folder...", "OK"} default button "OK" with icon note
	else
		set resultDialog to display dialog resultText with title "MDLBSG Compressor" buttons {"Save Folder...", "OK"} default button "OK" with icon compressorIcon
	end if

	if button returned of resultDialog is "Save Folder..." then
		try
			set chosenFolder to POSIX path of (choose folder with prompt "Where should MDLBSG save its output?")

			if compressorIcon is missing value then
				set saveDialog to display dialog "Save to this folder every time?" & return & return & chosenFolder with title "Save Location" buttons {"Just This Once", "Always Save Here"} default button "Always Save Here" with icon note
			else
				set saveDialog to display dialog "Save to this folder every time?" & return & return & chosenFolder with title "Save Location" buttons {"Just This Once", "Always Save Here"} default button "Always Save Here" with icon compressorIcon
			end if

			if button returned of saveDialog is "Always Save Here" then
				do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of chosenFolder & " > ~/.mdlbsg/destdir"
			else
				do shell script "/bin/rm -f ~/.mdlbsg/destdir"
			end if
		end try
	end if
end run
