struct LumenFixedCapacityRingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0
    private(set) var capacity: Int

    init(capacity: Int) {
        let capacity = max(capacity, 1)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }

    var first: Element? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    @discardableResult
    mutating func appendDroppingOldest(_ element: Element) -> Element? {
        if isFull {
            let dropped = storage[head]
            storage[head] = element
            head = (head + 1) % capacity
            return dropped
        }

        storage[(head + count) % capacity] = element
        count += 1
        return nil
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        if count == 0 {
            head = 0
        }
        return element
    }

    mutating func removeAll() {
        for offset in 0 ..< count {
            storage[(head + offset) % capacity] = nil
        }
        head = 0
        count = 0
    }

    @discardableResult
    mutating func resize(to requestedCapacity: Int) -> Int {
        let newCapacity = max(requestedCapacity, 1)
        guard newCapacity != capacity else { return 0 }

        let droppedCount = max(count - newCapacity, 0)
        let retainedCount = count - droppedCount
        var resizedStorage = [Element?](repeating: nil, count: newCapacity)
        for offset in 0 ..< retainedCount {
            resizedStorage[offset] =
                storage[(head + droppedCount + offset) % capacity]
        }

        storage = resizedStorage
        capacity = newCapacity
        head = 0
        count = retainedCount
        return droppedCount
    }
}
