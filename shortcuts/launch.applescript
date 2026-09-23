-- slipmat menu-bar launcher — ONE file, the mode comes in as an argument.
-- Each menu-bar Shortcut is a one-line delegator:
--     osascript <repo>/shortcuts/launch.applescript <repo> <mode>
-- so fixing behavior here fixes every Shortcut at once (edit-once rule).
--
-- Modes:
--   best    rip the best QuickTime-playable version of the copied URL, no questions
--   picker  numbered menu of the source's REAL resolutions
--   studio  picker + the re-encode concierge; also takes a FILE copied in Finder
--   audio   best audio -> AAC-320 .m4a (square art, booth-safe)
--   spotify a Spotify track/album/playlist link -> the same AAC-320 .m4a
--   crop    unattended zoom-crop batch of the Finder SELECTION (or a copied path)
--
-- Clipboard rule (field-proven): read TEXT first and let it win whenever it
-- looks like a URL — AppleScript happily coerces URL *text* to a file
-- reference and mangles it into "/https/::host:path". The file coercion runs
-- only otherwise, and only counts if the path really exists on disk.

on run argv
	set repoPath to item 1 of argv
	set mode to item 2 of argv
	set slip to repoPath & "/slipmat"

	if mode is "crop" then
		set items_ to {}
		try
			tell application "Finder"
				set sel to selection
				repeat with sitem in sel
					set end of items_ to POSIX path of (sitem as alias)
				end repeat
			end tell
		end try
		if (count of items_) is 0 then
			set p to ""
			try
				set p to do shell script "pbpaste"
			end try
			if p is not "" and p does not start with "http" then
				try
					do shell script "test -e " & quoted form of p
					set end of items_ to p
				end try
			end if
			if (count of items_) is 0 then
				try
					set p to POSIX path of (the clipboard as «class furl»)
					do shell script "test -e " & quoted form of p
					set end of items_ to p
				end try
			end if
		end if
		if (count of items_) is 0 then
			display alert "SLIPMAT — AUTO CROP" message "Nothing to batch. Select files or folders in Finder (or copy one), then run again." as warning
			return
		end if
		set argstr to ""
		repeat with p in items_
			set argstr to argstr & " " & quoted form of p
		end repeat
		tell application "Terminal"
			activate
			do script quoted form of slip & " z-batch" & argstr
		end tell
		return
	end if

	-- URL modes (studio also accepts a copied file)
	set theURL to ""
	try
		set theURL to do shell script "pbpaste" -- URL text / copied pathname
	end try
	if mode is "studio" and theURL does not start with "http" then
		try
			set p to POSIX path of (the clipboard as «class furl») -- plain Cmd+C on a file
			do shell script "test -e " & quoted form of p
			set theURL to p
		end try
	end if
	if theURL is "" then
		if mode is "spotify" then
			display alert "SLIPMAT — SPOTIFY" message "Clipboard is empty. In Spotify: Share → Copy link (a track, album or playlist), then run again." as warning
		else if mode is "audio" then
			display alert "SLIPMAT — AUDIO" message "Clipboard is empty. Copy a link first, then run again." as warning
		else if mode is "studio" then
			display alert "SLIPMAT — STUDIO" message "Clipboard is empty. Copy a video URL — or a video file — first, then run again." as warning
		else
			display alert "SLIPMAT — VIDEO" message "Clipboard is empty. Copy a video URL first, then run again." as warning
		end if
		return
	end if

	set cmd to ""
	if mode is "best" then
		set cmd to quoted form of slip & " video " & quoted form of theURL & " best"
	else if mode is "picker" then
		set cmd to quoted form of slip & " video " & quoted form of theURL & " auto"
	else if mode is "studio" then
		set cmd to quoted form of slip & " video " & quoted form of theURL & " studio"
	else if mode is "audio" then
		set cmd to quoted form of slip & " audio " & quoted form of theURL
	else if mode is "spotify" then
		if theURL does not contain "spotify" then
			display alert "SLIPMAT — SPOTIFY" message "That's not a Spotify link. In Spotify: Share → Copy link (a track, album or playlist), then run again." as warning
			return
		end if
		set cmd to quoted form of slip & " spotify " & quoted form of theURL
	end if
	tell application "Terminal"
		activate
		do script cmd
	end tell
end run
