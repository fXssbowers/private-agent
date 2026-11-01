enum TaskStatus { succeeded, failed, cancelled }

class TaskResult {
  final TaskStatus status;
  final String message;
  const TaskResult(this.status, this.message);
  bool get success => status == TaskStatus.succeeded;
}
