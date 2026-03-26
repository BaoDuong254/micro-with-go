package service

import pb "ride-sharing/shared/proto/driver"

type driverInMap struct {
	Driver *pb.Driver
}

type Service struct {
	drivers []*driverInMap
}

func NewService() *Service {
	return &Service{
		drivers: make([]*driverInMap, 0),
	}
}
