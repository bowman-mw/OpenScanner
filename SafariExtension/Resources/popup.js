// popup.js
// Rescriva Safari extension
//
// The toolbar popup. On a web page it offers "Send this page to Rescriva" (the page as Safari shows
// it, saved as a PDF in Rescriva); on a PDF, "Open this PDF in Rescriva". Either way the link can go
// instead. Once something is sent, "Open Rescriva" opens the app, which imports it straight away.
// iOS opens an app only from a tap, so that's a button rather than automatic.

import {
	MAX_BYTES,
	capturePage,
	fileNameFromURL,
	looksLikePDFAddress,
	openRescriva,
	sendFile,
	sendLink,
	sendPDF,
	t,
	webAddress,
} from "./handoff.js";

const ui = {
	page: document.getElementById("page"),
	choices: document.getElementById("choices"),
	openPDF: document.getElementById("open-pdf"),
	sendPage: document.getElementById("send-page"),
	sendPageHint: document.getElementById("send-page-hint"),
	sendLink: document.getElementById("send-link"),
	sendLinkHint: document.getElementById("send-link-hint"),
	progress: document.getElementById("progress"),
	status: document.getElementById("status"),
	openRescriva: document.getElementById("open-rescriva"),
};

let tab;

start().catch((error) => showStatus(error.message, "problem"));

async function start() {
	for (const node of document.querySelectorAll("[data-i18n]")) {
		node.textContent = t(node.dataset.i18n);
	}
	[tab] = await browser.tabs.query({ active: true, currentWindow: true });
	if (!tab || !webAddress(tab.url)) {
		showStatus(t("cant_send"), "problem");
		return;
	}
	ui.page.textContent = tab.title || new URL(tab.url).host;
	const isPDF = await showsPDF(tab);
	ui.openPDF.hidden = !isPDF;
	ui.sendPage.hidden = isPDF;
	ui.sendPageHint.hidden = isPDF;
	ui.sendLink.hidden = false;
	ui.sendLinkHint.hidden = false;
}

/** True when the tab shows a PDF: by its address, by the document, or by asking the server. */
async function showsPDF(tab) {
	if (looksLikePDFAddress(tab.url)) {
		return true;
	}
	try {
		const [injection] = await browser.scripting.executeScript({
			target: { tabId: tab.id },
			func: () => document.contentType,
		});
		return injection?.result === "application/pdf";
	} catch {
		// Scripts can't run here: Safari's PDF viewer, or a page Safari keeps to itself.
		return servesPDF(tab.url);
	}
}

async function servesPDF(url) {
	try {
		const response = await fetch(url, { method: "HEAD", credentials: "include" });
		return (response.headers.get("Content-Type") || "").toLowerCase().includes("application/pdf");
	} catch {
		return false;
	}
}

ui.openPDF.addEventListener("click", () => {
	send(() => sendPDF(tab.url, tab.title || fileNameFromURL(tab.url), showProgress));
});

ui.sendPage.addEventListener("click", () => {
	send(sendPage);
});

ui.sendLink.addEventListener("click", () => {
	send(async () => {
		await sendLink(tab.url, tab.title);
		return "link";
	});
});

ui.openRescriva.addEventListener("click", async () => {
	try {
		await openRescriva(tab.id);
		window.close();
	} catch (error) {
		console.error("Rescriva: couldn't open the app:", error);
		showStatus(t("open_yourself"), "problem");
	}
});

/** The page as Safari shows it, saved as a PDF in Rescriva; the link when the page can't be read. */
async function sendPage() {
	let page;
	try {
		const [injection] = await browser.scripting.executeScript({ target: { tabId: tab.id }, func: capturePage });
		page = injection?.result;
	} catch (error) {
		console.log("Rescriva: couldn't read the page; sending the link:", error);
	}
	if (!page || !page.html) {
		await sendLink(tab.url, tab.title);
		return "link";
	}
	const blob = new Blob([page.html], { type: "text/html" });
	if (blob.size > MAX_BYTES) {
		await sendLink(tab.url, page.title || tab.title);
		return "link";
	}
	await sendFile("webPage", blob, { title: page.title || tab.title, sourceURL: page.url || tab.url }, showProgress);
	return "file";
}

/** Runs one send with the buttons held, then offers to open Rescriva. */
async function send(task) {
	setBusy(true);
	showStatus(t("sending"));
	try {
		const how = await task();
		ui.choices.hidden = true;
		ui.progress.hidden = true;
		showStatus(how === "link" ? t("sent_link") : t("sent"), "done");
		ui.openRescriva.hidden = false;
		ui.openRescriva.focus();
	} catch (error) {
		ui.progress.hidden = true;
		showStatus(error.message, "problem");
	} finally {
		setBusy(false);
	}
}

function setBusy(busy) {
	for (const button of [ui.openPDF, ui.sendPage, ui.sendLink]) {
		button.disabled = busy;
	}
}

function showProgress(fraction) {
	ui.progress.hidden = false;
	ui.progress.value = fraction;
}

function showStatus(message, tone = "") {
	ui.status.textContent = message;
	ui.status.className = `status ${tone}`.trim();
}
