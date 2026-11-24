--!strict
--[[
	Types — shared type definitions for BetterNotifications.

	Payload shapes mirror the Open Cloud v2 Luau package exactly (camelCase).
	See docs/RESEARCH.md §2 for the authoritative field table.
]]

local Types = {}

export type LogLevel = "error" | "warn" | "info" | "debug"

--[[ Open Cloud payload ----------------------------------------------------]]

-- Parameter values are typed wrappers, not bare primitives (RESEARCH.md §2).
export type ParameterValue = { int64Value: number } | { stringValue: string }

export type NotificationPayload = {
	messageId: string,
	type: string,
	parameters: { [string]: ParameterValue }?,
	joinExperience: { launchData: string }?,
	analyticsData: { category: string }?,
}

export type UserNotification = {
	payload: NotificationPayload,
}

--[[ Transport -------------------------------------------------------------]]

-- Normalised outcome of one transport attempt. `ok` means the API accepted the
-- request; it does NOT mean the notification was delivered (RESEARCH.md §6).
export type SendResult = {
	ok: boolean,
	statusCode: number,
	errorCode: string?,
	errorMessage: string?,
	notificationId: string?,
	retryable: boolean,
	terminal: boolean,
	threw: boolean,
	dryRun: boolean,
}

--[[ Registry --------------------------------------------------------------]]

-- A confidence model, not ground truth — opt-in status is not queryable
-- (RESEARCH.md §8).
export type RegistryState = "UNKNOWN" | "PROMPTED" | "LIKELY_OPTED_IN" | "NOT_ELIGIBLE"

export type RegistryEntry = {
	userId: number,
	state: RegistryState,
	promptedAt: number?,
	lastAttemptAt: number?,
	lastOkAt: number?,
	lastErrorCode: string?,
}

--[[ Public API ------------------------------------------------------------]]

-- Anything that can be resolved to a userId: a raw id, a Player, or a table
-- carrying `userId` / `UserId` (e.g. a RegistryEntry).
export type Target = number | Instance | { [string]: any }

export type NotificationSpec = {
	msg: string,
	params: { [string]: any }?,
	launchData: (string | { [string]: any })?,
	category: string?,
	priority: number?,
}

export type QueueItem = {
	userId: number,
	alias: string,
	payload: NotificationPayload,
	attempts: number,
	readyAt: number,
	priority: number,
	enqueuedAt: number,
	source: any,
}

export type Stats = {
	enqueued: number,
	sent: number,
	failed: number,
	retried: number,
	droppedDuplicate: number,
	droppedNotEligible: number,
	droppedQueueFull: number,
	scheduled: number,
	byErrorCode: { [string]: number },
	byStatusCode: { [number]: number },
}

return Types
