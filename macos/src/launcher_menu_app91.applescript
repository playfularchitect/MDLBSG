-- MDLBSG_NATIVE_MENU_APP_V91
-- MDLBSG_CACHE_OPT_IN_MENU_V89
-- MDLBSG_FRONTMOST_ACTIVATION_V90
-- MDLBSG_APPLET_RUN_HANDLER_FIX_V91
use AppleScript version "2.4"
use scripting additions
use framework "AppKit"

property compressorBundleID : "com.mdlbsg.compressor"
property launcherSelfTestMarker : "MDLBSG_APP91_MENU_APP_SELF_TEST_PASS"

on logLauncher(tag)
	try
		do shell script "mkdir -p ~/.mdlbsg && echo \"$(date '+%Y-%m-%d %H:%M:%S') launcher-v91 " & tag & "\" >> ~/.mdlbsg/launch.log"
	end try
end logLauncher


on bringMenuForward()
	try
		set menuApplication to current application's NSApplication's sharedApplication()
		menuApplication's activateIgnoringOtherApps:true
	end try
	activate
end bringMenuForward

on handleBundleSelfTest()
	set homePath to POSIX path of (path to home folder)
	set requestPath to homePath & ".mdlbsg/menu_app_self_test_request"
	try
		do shell script "test -f " & quoted form of requestPath
	on error
		return false
	end try
	try
		set proofPath to do shell script "cat " & quoted form of requestPath
		do shell script "rm -f " & quoted form of requestPath
		if proofPath is not "" then
			do shell script "/usr/bin/printf '%s' " & quoted form of launcherSelfTestMarker & " > " & quoted form of proofPath
		end if
	end try
	return true
end handleBundleSelfTest

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
	my bringMenuForward()
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
	do shell script "mkdir -p ~/.mdlbsg && printf '%s' " & quoted form of m & " > ~/.mdlbsg/preset"
end changeMode

on cacheEnabled()
	try
		do shell script "test -f ~/.mdlbsg/cache_enabled"
		return true
	on error
		return false
	end try
end cacheEnabled

on cacheStatusLine()
	if my cacheEnabled() then
		return "Plaintext cache: ON — repeat extraction can be nearly instant"
	end if
	return "Plaintext cache: OFF — cache copies are not created or used"
end cacheStatusLine

on clearCacheCopies()
	do shell script "rm -rf ~/.mdlbsg/cache"
	my bringMenuForward()
	display dialog "Cached plaintext copies were cleared." with title "MDLBSG Cache" buttons {"OK"} default button "OK" with icon note
end clearCacheCopies

on cacheSettings()
	my bringMenuForward()
	if my cacheEnabled() then
		set reply to display dialog "Plaintext cache is ON." & return & return & "MDLBSG may keep local plaintext copies of regular files up to 1 GB each under ~/.mdlbsg/cache. It keeps at most 3 entries with a 6 GB total cap." & return & return & "Disabling the cache stops new cache use. Existing cached copies remain until cleared." with title "MDLBSG Cache" buttons {"Cancel", "Clear Copies", "Disable Cache"} default button "Disable Cache" with icon caution
		set chosenButton to button returned of reply
		if chosenButton is "Disable Cache" then
			do shell script "rm -f ~/.mdlbsg/cache_enabled ~/.mdlbsg/cache_off"
			my logLauncher("cache-disabled")
		else if chosenButton is "Clear Copies" then
			my clearCacheCopies()
		end if
	else
		set reply to display dialog "Plaintext cache is OFF by default." & return & return & "If enabled, MDLBSG may keep local plaintext copies of regular files up to 1 GB each under ~/.mdlbsg/cache. It keeps at most 3 entries with a 6 GB total cap. This can make repeat extraction nearly instant." & return & return & "Enable it only if you want that speed-for-local-storage tradeoff." with title "MDLBSG Cache" buttons {"Cancel", "Clear Copies", "Enable Cache"} default button "Enable Cache" with icon caution
		set chosenButton to button returned of reply
		if chosenButton is "Enable Cache" then
			do shell script "mkdir -p ~/.mdlbsg && rm -f ~/.mdlbsg/cache_off && : > ~/.mdlbsg/cache_enabled"
			my logLauncher("cache-enabled")
		else if chosenButton is "Clear Copies" then
			my clearCacheCopies()
		end if
	end if
end cacheSettings

on mainMenu(modeLine, cacheLine)
	try
		my bringMenuForward()
		set alert to current application's NSAlert's alloc()'s init()
		alert's setMessageText:"MDLBSG Compressor"
		alert's setInformativeText:(modeLine & return & cacheLine & return & return & "Files and folders are compressed to a .mdl archive and saved to your chosen folder. Folders are compressed as a single unit." & return & return & "You can also drag files or folders onto the app's icon.")
		alert's setAlertStyle:1
		alert's addButtonWithTitle:"Choose Files"
		alert's addButtonWithTitle:"Choose Folder"
		alert's addButtonWithTitle:"Change Mode"
		alert's addButtonWithTitle:"Cache Settings..."
		alert's addButtonWithTitle:"Quit"
		set answer to (alert's runModal()) as integer
		if answer is 1000 then return "files"
		if answer is 1001 then return "folder"
		if answer is 1002 then return "mode"
		if answer is 1003 then return "cache"
		return "quit"
	on error errMsg number errNum
		my logLauncher("menu-error " & (errNum as text) & " " & errMsg)
		return "quit"
	end try
end mainMenu

on sendPaths(thePaths)
	if (count of thePaths) is 0 then return
	set cmd to "/usr/bin/open -b " & quoted form of compressorBundleID
	repeat with p in thePaths
		set cmd to cmd & " " & quoted form of (p as text)
	end repeat
	do shell script cmd
end sendPaths

-- A compiled script application receives a parameterless run event when opened.
-- The previous `on run argv` form is for osascript command-line arguments and caused
-- macOS app launches to fail with AppleScript error -1700 before this body started.
on run
	if my handleBundleSelfTest() then return launcherSelfTestMarker

	my logLauncher("started")
	my bringMenuForward()
	-- A short grace period lets an initial drag deliver its open event first.
	-- The Compressor's open handler kills this helper before any menu appears.
	delay 0.7
	try
		repeat
			set m to my currentMode()
			set act to my mainMenu("Compression mode: " & my modeDetail(m), my cacheStatusLine())
			if act is "quit" then return
			if act is "mode" then
				my changeMode()
			else if act is "cache" then
				my cacheSettings()
			else if act is "files" then
				try
					set picked to choose file with prompt "Choose files to compress:" default location (path to downloads folder) with multiple selections allowed
					set pathsOut to {}
					repeat with pf in picked
						set end of pathsOut to POSIX path of pf
					end repeat
					my sendPaths(pathsOut)
					return
				on error number -128
				end try
			else if act is "folder" then
				try
					set f to POSIX path of (choose folder with prompt "Choose a folder to compress:" default location (path to downloads folder))
					my sendPaths({f})
					return
				on error number -128
				end try
			end if
		end repeat
	on error errMsg number errNum
		my logLauncher("fatal-error " & (errNum as text) & " " & errMsg)
		my bringMenuForward()
		display dialog "The MDLBSG menu could not open." & return & return & errMsg with title "MDLBSG Compressor" buttons {"OK"} default button "OK" with icon caution
	end try
end run
