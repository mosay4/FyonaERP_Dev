from abc import ABC, abstractmethod
from typing import Optional, List, Tuple
from uuid import UUID
from datetime import date
from app.domain.entities.hr_entities import (
    Department,
    Position,
    Employee,
    Attendance,
    Leave,
    Payroll,
)


class DepartmentRepository(ABC):
    @abstractmethod
    async def create(self, d: Department) -> Department: ...
    @abstractmethod
    async def get_by_id(self, id: UUID, org_id: UUID) -> Optional[Department]: ...
    @abstractmethod
    async def update(self, d: Department) -> Department: ...
    @abstractmethod
    async def list(self, org_id: UUID) -> List[Department]: ...


class PositionRepository(ABC):
    @abstractmethod
    async def create(self, p: Position) -> Position: ...
    @abstractmethod
    async def get_by_id(self, id: UUID, org_id: UUID) -> Optional[Position]: ...
    @abstractmethod
    async def update(self, p: Position) -> Position: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, dept_id: Optional[UUID] = None
    ) -> List[Position]: ...


class EmployeeRepository(ABC):
    @abstractmethod
    async def create(self, e: Employee) -> Employee: ...
    @abstractmethod
    async def get_by_id(self, id: UUID, org_id: UUID) -> Optional[Employee]: ...
    @abstractmethod
    async def update(self, e: Employee) -> Employee: ...
    @abstractmethod
    async def soft_delete(self, id: UUID, org_id: UUID) -> None: ...
    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        dept_id: Optional[UUID] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[Employee], int]: ...
    @abstractmethod
    async def count(self, org_id: UUID, status: Optional[str] = None) -> int: ...


class AttendanceRepository(ABC):
    @abstractmethod
    async def create(self, a: Attendance) -> Attendance: ...
    @abstractmethod
    async def update(self, a: Attendance) -> Attendance: ...
    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        emp_id: Optional[UUID] = None,
        from_date: Optional[date] = None,
        to_date: Optional[date] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[Attendance], int]: ...


class LeaveRepository(ABC):
    @abstractmethod
    async def create(self, l: Leave) -> Leave: ...
    @abstractmethod
    async def get_by_id(self, id: UUID, org_id: UUID) -> Optional[Leave]: ...
    @abstractmethod
    async def update(self, l: Leave) -> Leave: ...
    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        emp_id: Optional[UUID] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[Leave], int]: ...
    @abstractmethod
    async def count_pending(self, org_id: UUID) -> int: ...


class PayrollRepository(ABC):
    @abstractmethod
    async def create(self, p: Payroll) -> Payroll: ...
    @abstractmethod
    async def get_by_id(self, id: UUID, org_id: UUID) -> Optional[Payroll]: ...
    @abstractmethod
    async def update(self, p: Payroll) -> Payroll: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[Payroll], int]: ...
