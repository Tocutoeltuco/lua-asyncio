--[[REQUIRED]]local TimerList do local time = os.time TimerList = {} local meta = {__index = TimerList} function TimerList.new(obj) return setmetatable(obj or {}, meta) end function TimerList:add(timer) timer.list = self if not self.last then self.last = timer elseif self.last.when < timer.when then local current, last = self.last.previous, self.last while current and current.when < timer.when do current, last = current.previous, current end timer.previous, last.previous = current, timer else timer.previous = self.last self.last = timer end return timer end function TimerList:run() local now, current = time(), self.last while current and current.when <= now do current:callback() current = current.previous end self.last = current end function TimerList:remove(timer) if self.last == timer then self.last = timer.previous return end local current, last = self.last.previous, self.last while current and current ~= timer do current, last = current.previous, current end if current then last.previous = timer.previous end end end
--[[REQUIRED]]local Task do local remove = table.remove local unpack = table.unpack local create = coroutine.create local resume = coroutine.resume local status = coroutine.status Task = {} local meta = {__index = Task} function Task.new(fnc, args, obj) obj = obj or {} obj.arguments = args obj.coro = create(fnc) obj.futures = {} obj.futures_index = 0 return setmetatable(obj, meta) end function Task:cancel() if self.timer then self.timer.list:remove(self.timer) self.timer.event_loop:add_task(self) elseif self.awaiting then self.awaiting:cancel() end self.cancelled = true end function Task:run(loop) self.ran_once = true local data if self.arguments then data = {resume(self.coro, unpack(self.arguments))} self.arguments = nil else data = {resume(self.coro)} end while data[2] == "get_event_loop" do data = {resume(self.coro, loop)} end if not self.cancelled then if status(self.coro) == "dead" then self.done = true if data[1] then if self.futures_index > 0 or self._next_task then remove(data, 1) else return end local future for index = 1, self.futures_index do future = self.futures[index] future.obj:set_result(data, true, future.index) end if self._next_task then self._next_task.arguments = data self._next_task.awaiting = nil loop:add_task(self._next_task) end else self.error = debug.traceback(self.coro, data[2]) end end end end function Task:add_future(future, index) self.futures_index = self.futures_index + 1 self.futures[self.futures_index] = {obj=future, index=index} end end
--[[REQUIRED]]local function async(fnc) return function(...) return Task.new(fnc, {...}, {}) end end
--[[REQUIRED]]local Future do Future = {} local meta = {__index = Future} function Future.new(loop, obj) obj = obj or {} obj._is_future = true obj.loop = loop obj._next_tasks = {} obj._next_tasks_index = 0 obj.futures = {} obj.futures_index = 0 return setmetatable(obj, meta) end function Future:cancel() self.cancelled = true end function Future:add_future(future, index) self.futures_index = self.futures_index + 1 self.futures[self.futures_index] = {obj=future, index=index} end function Future:set_result(result, safe) if self.done then local msg = "The Future has already been done." if safe then return msg else error(msg, 2) end elseif self.cancelled then local msg = "The Future was cancelled." if safe then return msg else error(msg, 2) end end self.done = true self.result = result local future for index = 1, self.futures_index do future = self.futures[index] future.obj:set_result(result, true, future.index) end local task for index = 1, self._next_tasks_index do task = self._next_tasks[index] task.arguments = result task.awaiting = nil self.loop:add_task(task) end end function Future:set_error(result, index, safe) if self.done then local msg = "The Future has already been done." if safe then return msg else error(msg, 2) end elseif self.cancelled then local msg = "The Future was cancelled." if safe then return msg else error(msg, 2) end end result = debug.traceback(result, 2) self.error = result self.done = true local future for index = 1, self.futures_index do future = self.futures[index] future.obj:set_error(result, true, future.index) end local task for index = 1, self._next_tasks_index do task = self._next_tasks[index] if task.stop_error_propagation then task.arguments = nil else task.error = result task.done = true end task.awaiting = nil self.loop:add_task(task) end end end
--[[REQUIRED]]local FutureSemaphore do FutureSemaphore = setmetatable( {}, {__index=Future} ) local meta = {__index = FutureSemaphore} function FutureSemaphore.new(loop, quantity, obj) obj = Future.new(loop, obj) obj.quantity = quantity obj._done = 0 obj._result = {} return setmetatable(obj, meta) end function FutureSemaphore:set_result(result, safe, index) if self.done then local msg = "The FutureSemaphore has already been done." if safe then return msg else error(msg, 2) end elseif self.cancelled then local msg = "The FutureSemaphore was cancelled." if safe then return msg else error(msg, 2) end end if not self._result[index] then self._result[index] = result self._done = self._done + 1 else local msg = "The given semaphore spot is already taken." if safe then return msg else error(msg, 2) end end if self._done == self.quantity then self.done = true self.result = self._result local future for index = 1, self.futures_index do future = self.futures[index] future.obj:set_result(self.result, true, future.index) end local task_result, task = {self.result} for _index = 1, self._next_tasks_index do task = self._next_tasks[_index] task.arguments = task_result task.awaiting = nil self.loop:add_task(task) end end end function FutureSemaphore:set_error(result, safe, index) result = debug.traceback(result, 2) return self:set_result(result, safe, index) end end
--[[OPTIONAL]]local Queue do Queue = {} local meta = {__index = Queue} function Queue.new(loop, maxsize, obj) obj = obj or {} obj.loop = loop obj.maxsize = maxsize or 0 obj.waiting_free = {} obj.waiting_free_append = 0 obj.waiting_free_give = 0 obj.waiting_item = {} obj.waiting_item_append = 0 obj.waiting_item_give = 0 obj.size = 0 obj.real_size = 0 return setmetatable(obj, meta) end function Queue:full() return self.maxsize > 0 and self.size >= self.maxsize end function Queue:empty() return self.size == 0 end function Queue:trigger_add() local ret, give, task = false, self.waiting_item_give while give < self.waiting_item_append do give = give + 1 task = self.waiting_item[give] self.waiting_item[give] = nil if not task.cancelled and not task.done then self.loop:add_task(task) ret = true break end end self.waiting_item_give = give return ret end function Queue:trigger_remove() local ret, give, task = false, self.waiting_free_give while give < self.waiting_free_append do give = give + 1 task = self.waiting_free[give] self.waiting_free[give] = nil if not task.cancelled and not task.done then self.loop:add_task(task) ret = true break end end self.waiting_free_give = give return ret end function Queue:add_nowait(item, safe) if self:full() then if safe then return false end error("Can't add an item to a full queue", 2) end self.real_size = self.real_size + 1 if not self.first then self.first, self.last = item, item else self.last.next, self.last = item, item end if not self:trigger_add() then self.size = self.size + 1 end return true end Queue.add = async(function(self, item) local was_waiting if self:full() then was_waiting = true self.waiting_free_append = self.waiting_free_append + 1 self.waiting_free[self.waiting_free_append] = self.loop.current_task self.loop:stop_task_execution() end self.real_size = self.real_size + 1 if not self.first then self.first, self.last = item, item else self.last.next, self.last = item, item end if not was_waiting and not self:trigger_add() then self.size = self.size + 1 end end) function Queue:get_nowait(safe) if self:empty() then if safe then return false end error("Can't get an item from an empty queue", 2) end self.real_size = self.real_size - 1 item, self.first = self.first, self.first.next item.next = nil if not self.first then self.last = nil end if not self:trigger_remove() then self.size = self.size - 1 end return item end Queue.get = async(function(self) local was_waiting if self:empty() then was_waiting = true self.waiting_item_append = self.waiting_item_append + 1 self.waiting_item[self.waiting_item_append] = self.loop.current_task self.loop:stop_task_execution() end self.real_size = self.real_size - 1 item, self.first = self.first, self.first.next item.next = nil if not self.first then self.last = nil end if not was_waiting and not self:trigger_remove() then self.size = self.size - 1 end return item end) end
--[[OPTIONAL]]local LifoQueue do LifoQueue = setmetatable( {}, {__index = Queue} ) local meta = {__index = LifoQueue} function LifoQueue.new(loop, maxsize, obj) return setmetatable(Queue.new(loop, maxsize, obj or {}), meta) end function LifoQueue:add_nowait(item, safe) if self:full() then if safe then return false end error("Can't add an item to a full queue", 2) end self.real_size = self.real_size + 1 if not self.first then self.first, self.last = item, item else item.next, self.first = self.first, item end if not self:trigger_add() then self.size = self.size + 1 end return true end LifoQueue.add = async(function(self, item) local was_waiting if self:full() then was_waiting = true self.waiting_free_append = self.waiting_free_append + 1 self.waiting_free[self.waiting_free_append] = self.loop.current_task self.loop:stop_task_execution() end self.real_size = self.real_size + 1 if not self.first then self.first, self.last = item, item else item.next, self.first = self.first, item end if not was_waiting and not self:trigger_add() then self.size = self.size + 1 end end) end
--[[OPTIONAL]]local Lock do Lock = {} local meta = {__index = Lock} function Lock.new(loop, obj) obj = obj or {} obj.loop = loop obj.tasks = {} obj.tasks_append = 0 obj.tasks_give = 0 return setmetatable(obj, meta) end Lock.acquire = async(function(self) if self.is_locked then self.tasks_append = self.tasks_append + 1 self.tasks[self.tasks_append] = self.loop.current_task self.loop:stop_task_execution() else self.is_locked = true end self.task = self.loop.current_task._next_task end) function Lock:release() if not self.is_locked then error("Can't release an unlocked lock.", 2) elseif self.loop.current_task ~= self.task then print(self.loop.current_task, self.task) error("Can't release the lock from a different task.", 2) end local give, task = self.tasks_give while give < self.tasks_append do give = give + 1 task = self.tasks[give] self.tasks[give] = nil if not task.cancelled and not task.done then self.loop:add_task(task) self.tasks_give = give self.task = task.task return end end self.tasks_give = give self.is_locked = false end end
--[[OPTIONAL]]local Event do Event = {} local meta = {__index = Event} function Event.new(loop, obj) obj = obj or {} obj.loop = loop obj.tasks = {} obj.tasks_index = 0 return setmetatable(obj, meta) end Event.wait = async(function(self) if self.is_set then return end self.tasks_index = self.tasks_index + 1 self.tasks[self.tasks_index] = self.loop.current_task self.loop:stop_task_execution() end) function Event:set() if self.is_set then return end self.is_set = true for index = 1, self.tasks_index do self.loop:add_task(self.tasks[index]) end end function Event:clear() if not self.is_set then return end self.is_set = false self.tasks_index = 0 self.tasks = {} end end
--[[OPTIONAL]]local get_event_loop do local yield = coroutine.yield function get_event_loop() return yield("get_event_loop") end end
--[[REQUIRED]]local EventLoop do local time = os.time local yield = coroutine.yield EventLoop = {} local meta = {__index = EventLoop} function EventLoop.new(obj) obj = obj or {} obj.timers = TimerList.new() obj.tasks = {} obj.removed = {} obj.tasks_index = 0 obj.removed_index = 0 return setmetatable(obj, meta) end function EventLoop.timers_callback(callback) callback.task.timer = nil return callback.event_loop:add_task(callback.task) end function EventLoop.cancel_awaitable(callback) if not callback.awaitable.done then callback.awaitable:cancel() end end function EventLoop:sleep(delay) return self:sleep_until(time() + delay, self.current_task) end function EventLoop:call_soon(delay, task, no_future) return self:schedule(time() + delay, task, no_future) end function EventLoop:sleep_until(when) self.current_task.timer = self.timers:add { callback = self.timers_callback, when = when or 0, task = self.current_task, event_loop = self } return self:stop_task_execution() end function EventLoop:schedule(when, task, no_future) if task.ran_once then error("Can't schedule a task that did already run or is running.") end task.timer = self.timers:add { callback = self.timers_callback, when = when or 0, task = task, event_loop = self } if not no_future then local future = self:new_object(Future) task:add_future(future) return future end end function EventLoop:add_task(task) self.tasks_index = self.tasks_index + 1 self.tasks[self.tasks_index] = task end function EventLoop:new_object(object, ...) return object.new(self, ...) end function EventLoop:stop_task_execution() self.current_task.paused = true return yield() end function EventLoop:await(aw) if aw.cancelled or aw.done then error("Can't await a cancelled or done awaitable.", 2) end if aw._is_future then aw._next_tasks_index = aw._next_tasks_index + 1 aw._next_tasks[aw._next_tasks_index] = self.current_task else if aw._next_task then error("Can't re-use a task. Use Futures instead.", 2) end aw.paused = false aw._next_task = self.current_task self:add_task(aw) end self.current_task.awaiting = aw return self:stop_task_execution() end function EventLoop:await_safe(aw) self.current_task.stop_error_propagation = true return self:await(aw) end function EventLoop:add_timeout(aw, timeout) self.timers:add { callback = self.cancel_awaitable, when = time() + timeout, awaitable = aw } end function EventLoop:await_for(aw, timeout) self:add_timeout(aw, timeout) return self:await_safe(aw) end function EventLoop:await_many(...) local length = select("#", ...) local semaphore = self:new_object(FutureSemaphore, length) local task for index = 1, length do task = select(index, ...) task:add_future(semaphore, index) if not task._is_future then self:add_task(task) end end return semaphore end function EventLoop:run() self.timers:run() self:run_tasks() self:remove_tasks() end function EventLoop:handle_error(task, index) self:remove_later(index) task.done = true if task.cancelled then task.error = "The task was cancelled." end local future for index = 1, task.futures_index do future = task.futures[index] future.obj:set_error(task.error, true, future.index) end if task._next_task then local _next = task._next_task if _next.stop_error_propagation then _next.arguments = nil else _next.error = task.error _next.done = true end self:add_task(_next) else error(task.error) end end function EventLoop:remove_later(index) self.removed_index = self.removed_index + 1 self.removed[self.removed_index] = index end function EventLoop:run_tasks() local tasks, now, task = self.tasks, time() for index = 1, self.tasks_index do task = tasks[index] if not task.cancelled then if task.error then self:handle_error(task, index) else self.current_task = task task:run(self) if task.cancelled or task.error then self:handle_error(task, index) elseif task.done or task.paused then task.paused = false self:remove_later(index) end end else self:handle_error(task, index) end end self.current_task = nil end function EventLoop:remove_tasks() local tasks, removed, remove = self.tasks, self.removed for index = 1, self.removed_index do remove = removed[index] if remove < self.tasks_index then tasks[remove] = tasks[self.tasks_index] end self.tasks_index = self.tasks_index - 1 end self.removed_index = 0 end end
--[[OPTIONAL]]local OrderedEventLoop do local remove = table.remove OrderedEventLoop = setmetatable( {}, {__index = EventLoop} ) local meta = {__index = OrderedEventLoop} function OrderedEventLoop.new(obj) return setmetatable(EventLoop.new(obj), meta) end function OrderedEventLoop:remove_tasks() local tasks, removed = self.tasks, self.removed for index = self.removed_index, 1, -1 do remove(tasks, removed[index]) end self.tasks_index = self.tasks_index - self.removed_index self.removed_index = 0 end end
--[[OPTIONAL]]local LimitedEventLoop do local time = os.time LimitedEventLoop = setmetatable( {}, {__index = EventLoop} ) local meta = {__index = LimitedEventLoop} function LimitedEventLoop.new(obj, runtime, reset) obj = EventLoop.new(obj) obj.runtime = runtime obj.reset = reset obj.used = 0 obj.initialized = 0 obj.step = 0 return setmetatable(obj, meta) end function LimitedEventLoop:can_run(now) return self.used + now < self.runtime end function LimitedEventLoop:run() local start = time() if start - self.initialized >= self.reset then self.initialized = start self.used = 0 end if self.step == 0 then if self:can_run(0) then self.timers:run() self.step = 1 end end if self.step == 1 then if self:can_run(time() - start) then self:run_tasks() self.step = 2 end end if self.step == 2 then if self:can_run(time() - start) then self:remove_tasks() self.step = 0 end end self.used = self.used + time() - start end end
--[[OPTIONAL]]local function MixedEventLoop(eventloop, ...) local classes = {...} local length = #classes setmetatable(eventloop, { __index = function(tbl, key) local v for i = 1, length do v = classes[i][key] if v then return v end end end }) local meta = {__index = eventloop} function eventloop.new(obj) local obj = obj or {} for i = 1, length do obj = classes[i].new(obj) end return setmetatable(obj, meta) end return eventloop end

local loop = LimitedEventLoop.new({}, 30, 4100)

-- Here starts your code. You can remove the lines marked with OPTIONAL.
-- Remember that it will remove functionalities too.

local async_eventChatCommand = async(function(name, command)
	print("Asynchronous event chat command!")
end)

function eventChatCommand(name, command)
	loop:add_task(async_eventChatCommand(name, command))
	loop:run()
end

function eventLoop()
	loop:run()
end