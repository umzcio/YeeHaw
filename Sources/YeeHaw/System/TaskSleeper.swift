import YeeHawCore

struct TaskSleeper: Sleeper {
    func sleep(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
