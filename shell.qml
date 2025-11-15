import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import Qt.labs.settings as Labs
import Quickshell
import Quickshell.Io as Io

FloatingWindow {
	id: wallpaperWindow
	title: "Wallpaper Picker"
	implicitWidth: 900
	implicitHeight: 600
	color: "#ae151217"

	// Color scheme
	readonly property color colorBackground: "#151217"
	readonly property color colorSurface: "#221e24"
	readonly property color colorSurfaceContainer: "#2c292e"
	readonly property color colorOnSurface: "#e8e0e8"
	readonly property color colorPrimary: "#dcb9f8"
	readonly property color colorError: "#ffb4ab"
	readonly property color colorOutline: "#4a454d"

	// Configuration
	property string homeDir: ""
	property string wallpaperDir: ""
	property string thumbnailDir: ""
	property var wallpapers: []
	property string selectedWallpaper: ""
	property string lastError: ""
	property bool hasFfmpeg: false
	property bool hasMatugen: false
	property bool settingsOpen: false
	
	// Cache for base names to avoid repeated calculations
	property var thumbnailPaths: ({})

	// Persistent settings for custom directories
	Labs.Settings {
		id: appSettings
		category: "WallpaperPicker"
		property string savedWallpaperDir: ""
		property string savedThumbnailDir: ""
	}

	// Keep settings in sync
	onWallpaperDirChanged: {
		if (wallpaperDir && wallpaperDir !== appSettings.savedWallpaperDir) {
			appSettings.savedWallpaperDir = wallpaperDir
		}
	}
	onThumbnailDirChanged: {
		if (thumbnailDir && thumbnailDir !== appSettings.savedThumbnailDir) {
			appSettings.savedThumbnailDir = thumbnailDir
		}
	}

	// Process for getting home directory
	Io.Process {
		id: homeProcess
		command: []
		stdout: Io.StdioCollector {
			id: homeCollector
		}
		onExited: function(exitCode, exitStatus) {
			if (exitCode === 0) {
				homeDir = homeCollector.text.trim()
				// Defaults
				let defaultWall = homeDir + "/Pictures/wall"
				let defaultThumb = homeDir + "/.cache/chwall_thumbnails"
				// Load saved settings if present
				wallpaperDir = appSettings.savedWallpaperDir && appSettings.savedWallpaperDir.length > 0 ? appSettings.savedWallpaperDir : defaultWall
				thumbnailDir = appSettings.savedThumbnailDir && appSettings.savedThumbnailDir.length > 0 ? appSettings.savedThumbnailDir : defaultThumb
				// Check dependencies first, then continue
				depsProcess.exec(["sh","-c","(command -v ffmpeg >/dev/null 2>&1 && echo FFOK); (command -v matugen >/dev/null 2>&1 && echo MTOK)"])
			} else {
				lastError = "Failed to get home directory"
				showNotification("Error", lastError, "dialog-error")
			}
		}
	}

	// Process for creating thumbnails (parallel generation)
	Io.Process {
		id: thumbnailProcess
		command: []
		onExited: function(exitCode, exitStatus) {
			if (exitCode === 0) {
				console.log("Thumbnails generated successfully")
			}
		}
	}

	// Process for executing matugen
	Io.Process {
		id: matugenProcess
		command: []
		onExited: function(exitCode, exitStatus) {
			if (exitCode === 0) {
				showNotification("Wallpaper Applied", "Wallpaper '" + selectedWallpaper + "' applied successfully", "dialog-information")
				wallpaperWindow.visible = false
				Qt.quit()
			} else {
				lastError = "Failed to apply wallpaper"
				showNotification("Error", lastError, "dialog-error")
			}
		}
	}

	// Dependency check process
	Io.Process {
		id: depsProcess
		command: []
		stdout: Io.StdioCollector { id: depsCollector }
		onExited: function(exitCode, exitStatus) {
			let out = depsCollector.text
			hasFfmpeg = out.indexOf("FFOK") !== -1
			hasMatugen = out.indexOf("MTOK") !== -1
			if (!hasFfmpeg) {
				showNotification("Warning", "ffmpeg not found. Thumbnails will be loaded from full images and may be slower.", "dialog-warning")
			}
			if (!hasMatugen) {
				showNotification("Warning", "matugen not found. You can browse wallpapers but cannot apply them.", "dialog-warning")
			}
			// Ensure thumbnail directory exists (even without ffmpeg)
			mkdirThumbsProcess.exec(["sh","-c","mkdir -p '" + thumbnailDir + "'"])
		}
	}

	// Ensure thumbnail directory exists
	Io.Process {
		id: mkdirThumbsProcess
		command: []
		onExited: function(exitCode, exitStatus) {
			validateWallDirProcess.exec(["sh","-c","[ -d '" + wallpaperDir + "' ] || exit 1"])
		}
	}

	// Validate wallpaper directory before listing
	Io.Process {
		id: validateWallDirProcess
		command: []
		onExited: function(exitCode, exitStatus) {
			if (exitCode !== 0) {
				lastError = "Wallpaper directory not found: " + wallpaperDir
				showNotification("Error", lastError, "dialog-error")
			} else {
				startListing()
			}
		}
	}

	// Process for listing wallpapers
	Io.Process {
		id: listProcess
		command: []
		stdout: Io.StdioCollector {
			id: listCollector
		}
		onExited: function(exitCode, exitStatus) {
			if (exitCode !== 0) {
				lastError = "Failed to scan wallpaper directory"
				showNotification("Error", lastError, "dialog-error")
			} else {
				// Parse and process files efficiently
				let output = listCollector.text.trim()
				if (output.length === 0) {
					lastError = "No wallpapers found in " + wallpaperDir
					showNotification("Error", lastError, "dialog-error")
					return
				}
				
				let files = output.split("\n").filter(f => f.length > 0)
				// Extract filenames and pre-calculate thumbnail paths
				let processed = []
				let paths = {}
				for (let i = 0; i < files.length; i++) {
					let filename = files[i].split("/").pop()
					if (filename.length > 0) {
						processed.push(filename)
						// Pre-calculate base name for thumbnail
						let parts = filename.split(".")
						let baseName = parts.length > 1 ? parts.slice(0, -1).join(".") : filename
						paths[filename] = baseName + ".png"
					}
				}
				
				wallpapers = processed
				thumbnailPaths = paths
				
				if (wallpapers.length === 0) {
					lastError = "No wallpapers found in " + wallpaperDir
					showNotification("Error", lastError, "dialog-error")
				} else {
					// Generate missing thumbnails in parallel (using xargs -P for parallel processing)
					let setupCmd = "mkdir -p '" + thumbnailDir + "' && find '" + wallpaperDir + "' -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.bmp' \\) -print0 | xargs -0 -P 4 -I {} bash -c 'base=$(basename \"{}\"); name=\"${base%.*}\"; thumb=\"" + thumbnailDir + "/${name}.png\"; [ ! -f \"$thumb\" ] && ffmpeg -i \"{}\" -vf \"scale=250:140:force_original_aspect_ratio=decrease,pad=250:140:(ow-iw)/2:(oh-ih)/2\" -q:v 5 -frames:v 1 \"$thumb\" 2>/dev/null || true'"
					thumbnailProcess.exec(["sh", "-c", setupCmd])
				}
			}
		}
	}

	Component.onCompleted: {
		// Get home directory first, then start listing
		homeProcess.exec(["sh", "-c", "echo $HOME"])
	}

	function startListing() {
		if (!wallpaperDir) {
			lastError = "Wallpaper directory not set"
			return
		}
		// Use ls for faster listing (faster than find for single directory)
		listProcess.exec(["sh", "-c", "ls -1 '" + wallpaperDir + "' 2>/dev/null | grep -iE '\\.(jpg|jpeg|png|webp|bmp)$' | sort"])
	}

	function showNotification(title, message, icon) {
		console.log("[" + title + "] " + message)
	}

	function applyWallpaper(wallpaperName) {
		selectedWallpaper = wallpaperName
		if (!hasMatugen) {
			lastError = "Cannot apply wallpaper: 'matugen' not found in PATH."
			showNotification("Error", lastError, "dialog-error")
			return
		}
		let fullPath = wallpaperDir + "/" + wallpaperName
		matugenProcess.exec(["matugen", "image", fullPath])
	}

	function randomWallpaper() {
		if (wallpapers.length > 1) {
			let newWallpaper = selectedWallpaper
			// Limit retries to avoid infinite loop
			for (let i = 0; i < 10 && newWallpaper === selectedWallpaper; i++) {
				let randomIndex = Math.floor(Math.random() * wallpapers.length)
				newWallpaper = wallpapers[randomIndex]
			}
			applyWallpaper(newWallpaper)
		}
	}

	ColumnLayout {
		anchors.fill: parent
		anchors.margins: 16
		spacing: 12

		Keys.onEscapePressed: Qt.quit()

		// Header
		RowLayout {
			Layout.fillWidth: true

			Text {
				text: "Select a Wallpaper"
				font.pixelSize: 24
				font.bold: true
				color: colorOnSurface
				Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
			}

			Item { Layout.fillWidth: true }

			Button {
				id: rescanBtn
				text: "Rescan"
				onClicked: startListing()
				background: Rectangle {
					radius: 8
					color: rescanBtn.down ? Qt.darker(colorSurfaceContainer, 1.3) : (rescanBtn.hovered ? Qt.lighter(colorSurfaceContainer, 1.2) : colorSurfaceContainer)
					border.color: colorOutline
					border.width: 1
				}
				contentItem: Text {
					text: rescanBtn.text
					color: colorOnSurface
					font.pixelSize: 14
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					elide: Text.ElideRight
				}
			}
			Button {
				id: randomBtn
				text: "Random"
				onClicked: randomWallpaper()
				background: Rectangle {
					radius: 8
					color: randomBtn.down ? Qt.darker(colorSurfaceContainer, 1.3) : (randomBtn.hovered ? Qt.lighter(colorSurfaceContainer, 1.2) : colorSurfaceContainer)
					border.color: colorOutline
					border.width: 1
				}
				contentItem: Text {
					text: randomBtn.text
					color: colorOnSurface
					font.pixelSize: 14
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					elide: Text.ElideRight
				}
			}
			Button {
				id: settingsBtn
				text: "Settings"
				onClicked: settingsOpen = true
				background: Rectangle {
					radius: 8
					color: settingsBtn.down ? Qt.darker(colorSurfaceContainer, 1.3) : (settingsBtn.hovered ? Qt.lighter(colorSurfaceContainer, 1.2) : colorSurfaceContainer)
					border.color: colorOutline
					border.width: 1
				}
				contentItem: Text {
					text: settingsBtn.text
					color: colorOnSurface
					font.pixelSize: 14
					horizontalAlignment: Text.AlignHCenter
					verticalAlignment: Text.AlignVCenter
					elide: Text.ElideRight
				}
			}
		}

		// Error message
		Rectangle {
			visible: lastError !== ""
			color: colorError
			radius: 4
			height: 40
			Layout.fillWidth: true

			Text {
				text: lastError
				color: colorOnSurface
				font.pixelSize: 12
				anchors.centerIn: parent
			}
		}

		// Wallpaper grid - Optimized GridLayout with efficient rendering
		ScrollView {
			Layout.fillWidth: true
			Layout.fillHeight: true
			ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

			GridLayout {
				id: wallpaperGrid
				width: wallpaperWindow.width - 32
				columns: Math.max(1, Math.floor(width / 260))
				rowSpacing: 16
				columnSpacing: 16

				Repeater {
					id: wallpaperGridView
					model: wallpapers

					Rectangle {
						id: wallpaperItem
						width: (wallpaperGrid.width - (wallpaperGrid.columns - 1) * wallpaperGrid.columnSpacing) / wallpaperGrid.columns
						height: width * 9 / 16
						color: colorSurface
						radius: 8
						border.color: selectedWallpaper === modelData ? colorPrimary : "transparent"
						border.width: 2

						MouseArea {
							anchors.fill: parent
							hoverEnabled: true
							onClicked: {
								selectedWallpaper = modelData
								applyWallpaper(modelData)
							}
						}

						// Wallpaper preview - optimized with pre-calculated paths
						Image {
							id: wallpaperImage
							anchors.fill: parent
							anchors.margins: 8
							property string thumbPath: thumbnailPaths[modelData] || ""
							source: thumbPath ? ("file://" + thumbnailDir + "/" + thumbPath) : ""
							fillMode: Image.PreserveAspectCrop
							smooth: true
							asynchronous: true
							cache: true
							mipmap: true

							onStatusChanged: {
								if (status === Image.Error && source !== "") {
									source = "file://" + wallpaperDir + "/" + modelData
								}
							}

							BusyIndicator {
								anchors.centerIn: parent
								running: parent.status === Image.Loading
								width: 40
								height: 40
								visible: running
							}
						}

						// Wallpaper name overlay
						Rectangle {
							width: parent.width
							height: 30
							color: "#00000066"
							anchors.bottom: parent.bottom
							radius: 0

							Text {
								text: modelData
								color: colorOnSurface
								font.pixelSize: 10
								elide: Text.ElideRight
								anchors.fill: parent
								anchors.margins: 4
								verticalAlignment: Text.AlignVCenter
								horizontalAlignment: Text.AlignHCenter
							}
						}

						// Checkmark for selected
						Rectangle {
							visible: selectedWallpaper === modelData
							width: 24
							height: 24
							radius: 12
							color: colorPrimary
							anchors.top: parent.top
							anchors.right: parent.right
							anchors.margins: 4

							Text {
								text: "✓"
								color: colorBackground
								font.bold: true
								font.pixelSize: 16
								anchors.centerIn: parent
							}
						}
					}
				}
			}
		}

		// Status text
		Text {
			text: wallpapers.length > 0 ? `Loaded ${wallpapers.length} wallpapers` : "Loading wallpapers..."
			font.pixelSize: 11
			color: colorOutline
			Layout.alignment: Qt.AlignRight | Qt.AlignBottom
		}
		
		// Settings dialog
		Dialog {
			id: settingsDialog
			visible: settingsOpen
			modal: true
			title: "Settings"
			width: 720
			height: 460
			padding: 16
			onVisibleChanged: if (!visible) settingsOpen = false
			background: Rectangle {
				radius: 12
				color: colorSurface
				border.color: colorOutline
				border.width: 1
			}
			onAccepted: {
				// Apply directories from fields and persist
				wallpaperDir = wallDirField.text.trim()
				thumbnailDir = thumbDirField.text.trim()
				// Re-validate and rescan
				mkdirThumbsProcess.exec(["sh","-c","mkdir -p '" + thumbnailDir + "'"])
			}
			contentItem: ColumnLayout {
				spacing: 12
				RowLayout {
					Layout.fillWidth: true
					Label { text: "Wallpaper directory:"; color: colorOnSurface }
					TextField { id: wallDirField; text: wallpaperDir; Layout.fillWidth: true }
					Button {
						id: browseWallBtn
						text: "Browse"
						background: Rectangle { radius: 8; color: browseWallBtn.down ? Qt.darker(colorSurfaceContainer, 1.3) : (browseWallBtn.hovered ? Qt.lighter(colorSurfaceContainer, 1.2) : colorSurfaceContainer); border.color: colorOutline; border.width: 1 }
						contentItem: Text { text: browseWallBtn.text; color: colorOnSurface; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
						onClicked: wallpaperFolderDialog.open()
					}
				}
				RowLayout {
					Layout.fillWidth: true
					Label { text: "Thumbnail directory:"; color: colorOnSurface }
					TextField { id: thumbDirField; text: thumbnailDir; Layout.fillWidth: true }
					Button {
						id: browseThumbBtn
						text: "Browse"
						background: Rectangle { radius: 8; color: browseThumbBtn.down ? Qt.darker(colorSurfaceContainer, 1.3) : (browseThumbBtn.hovered ? Qt.lighter(colorSurfaceContainer, 1.2) : colorSurfaceContainer); border.color: colorOutline; border.width: 1 }
						contentItem: Text { text: browseThumbBtn.text; color: colorOnSurface; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
						onClicked: thumbnailFolderDialog.open()
					}
				}
				RowLayout {
					spacing: 16
					Text { text: hasFfmpeg ? "ffmpeg: OK" : "ffmpeg: not found"; color: hasFfmpeg ? "#84e1a7" : colorError }
					Text { text: hasMatugen ? "matugen: OK" : "matugen: not found"; color: hasMatugen ? "#84e1a7" : colorError }
				}
			}
			footer: DialogButtonBox {
				alignment: Qt.AlignRight
				Button {
					id: cancelBtn
					text: "Cancel"
					DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
					background: Rectangle { radius: 8; color: cancelBtn.down ? Qt.darker(colorSurfaceContainer, 1.3) : (cancelBtn.hovered ? Qt.lighter(colorSurfaceContainer, 1.2) : colorSurfaceContainer); border.color: colorOutline; border.width: 1 }
					contentItem: Text { text: cancelBtn.text; color: colorOnSurface; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
				}
				Button {
					id: saveBtn
					text: "Save"
					DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
					background: Rectangle { radius: 8; color: saveBtn.down ? Qt.darker(colorSurfaceContainer, 1.3) : (saveBtn.hovered ? Qt.lighter(colorSurfaceContainer, 1.2) : colorSurfaceContainer); border.color: colorOutline; border.width: 1 }
					contentItem: Text { text: saveBtn.text; color: colorOnSurface; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
				}
			}
		}

		FolderDialog {
			id: wallpaperFolderDialog
			title: "Choose wallpaper directory"
			onAccepted: {
				wallpaperDir = wallpaperFolderDialog.selectedFolder
				settingsOpen = true
			}
		}
		FolderDialog {
			id: thumbnailFolderDialog
			title: "Choose thumbnail directory"
			onAccepted: {
				thumbnailDir = thumbnailFolderDialog.selectedFolder
				settingsOpen = true
			}
		}
	}
}
