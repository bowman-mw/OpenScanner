// background.js
// Rescriva Safari extension
//
// "Open in Rescriva" on links to PDFs, in Safari's context menu. Safari has extension context
// menus on the Mac; on iPhone and iPad there's no such menu, and the popup does this job.

import { fileNameFromURL, openRescriva, sendPDF, t } from "./handoff.js";

const MENU_ID = "open-in-rescriva";
const PDF_LINKS = ["*://*/*.pdf", "*://*/*.pdf?*", "*://*/*.PDF", "*://*/*.PDF?*"];

const menus = browser.contextMenus || browser.menus;

if (menus) {
	addMenu();
	menus.onClicked.addListener((info, tab) => {
		if (info.menuItemId === MENU_ID && info.linkUrl) {
			openLink(info.linkUrl, tab);
		}
	});
}

/** Adds the menu item afresh each time the background script starts. */
async function addMenu() {
	await menus.removeAll();
	const item = { id: MENU_ID, title: t("open_in_rescriva"), contexts: ["link"] };
	try {
		menus.create({ ...item, targetUrlPatterns: PDF_LINKS });
	} catch (error) {
		// Without link patterns the item shows on every link; sendPDF still checks for a PDF.
		console.log("Rescriva: link patterns unsupported:", error);
		menus.create(item);
	}
}

/** Sends the linked PDF, then opens Rescriva. A failure marks the toolbar button for that tab. */
async function openLink(url, tab) {
	try {
		await sendPDF(url, fileNameFromURL(url));
		if (tab && tab.id !== undefined) {
			await browser.action.setBadgeText({ tabId: tab.id, text: "" });
			await openRescriva(tab.id);
		}
	} catch (error) {
		console.error("Rescriva: couldn't send the PDF:", error);
		if (tab && tab.id !== undefined) {
			await browser.action.setBadgeText({ tabId: tab.id, text: "!" });
			await browser.action.setTitle({ tabId: tab.id, title: `${t("error_menu")} ${error.message}` });
		}
	}
}
