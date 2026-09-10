package device

import (
	serviceDevice "befriend/internal/services/device"
)

type DeviceHandler struct {
	deviceService serviceDevice.DeviceService
}

func NewDeviceHandler(deviceService serviceDevice.DeviceService) *DeviceHandler {
	return &DeviceHandler{
		deviceService: deviceService,
	}
}
