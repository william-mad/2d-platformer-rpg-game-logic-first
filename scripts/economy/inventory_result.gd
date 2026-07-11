class_name InventoryResult
extends RefCounted

enum Code {
	SUCCESS,
	INVALID_ITEM_ID,
	INVALID_QUANTITY,
	INSUFFICIENT_AVAILABLE_QUANTITY,
	RESERVATION_ID_REQUIRED,
	RESERVATION_ALREADY_EXISTS,
	RESERVATION_NOT_FOUND,
	INVALID_RESERVATION_DATA,
	INVALID_SAVE_DATA,
}

var success: bool = false
var code: Code = Code.SUCCESS
var message: String = ""
var item_id: StringName = &""
var requested_quantity: int = 0
var available_quantity: int = 0
var reservation_id: StringName = &""


static func succeeded(message_text: String = "Operation succeeded.", reservation: StringName = &"") -> InventoryResult:
	var result := InventoryResult.new()
	result.success = true
	result.code = Code.SUCCESS
	result.message = message_text
	result.reservation_id = reservation
	return result


static func failed(
		failure_code: Code,
		message_text: String,
		item: StringName = &"",
		requested: int = 0,
		available: int = 0,
		reservation: StringName = &"") -> InventoryResult:
	var result := InventoryResult.new()
	result.success = false
	result.code = failure_code
	result.message = message_text
	result.item_id = item
	result.requested_quantity = requested
	result.available_quantity = available
	result.reservation_id = reservation
	return result
