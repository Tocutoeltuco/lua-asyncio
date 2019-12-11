local TimerList = require "timer_list"
local Future, FutureSemaphore = require "futures"
local Task, async = require "tasks"

local EventLoop
do
	local time = os.time
	local yield = coroutine.yield

	EventLoop = {}
	local meta = {__index = EventLoop}

	--[[@
		@name new
		@desc Creates a new instance of EventLoop: an object that runs tasks concurrently (pseudo-paralellism)
		@desc /!\ EventLoop.tasks_index might be lower than the quantity of items in the EventLoop.tasks list.
		@desc /!\ EventLoop.removed_index might be lower than the quantity of items in the EventLoop.removed list.
		@desc /!\ The tasks might run in a different order than the one the acquire once you run EventLoop:add_task
		@param obj?<table> The table to turn into an EventLoop.
		@returns EventLoop The EventLoop.
		@struct {
			timers = TimerList, -- A list of the timers the EventLoop will handle
			tasks = {}, -- The list of tasks the EventLoop is running
			removed = {}, -- The list of indexes in the tasks list to remove
			tasks_index = 0, -- The tasks list pointer
			removed_index = 0 -- The removed list pointer
		}
	]]
	function EventLoop.new(obj)
		obj = obj or {}
		obj.timers = TimerList.new()
		obj.tasks = {}
		obj.removed = {}
		obj.tasks_index = 0
		obj.removed_index = 0
		return setmetatable(obj, meta)
	end

	--[[@
		@name timers_callback
		@desc This function is called when a timer executes. It adds the timer task to the EventLoop.
		@params callback<Timer> The timer that is being executed
	]]
	function EventLoop.timers_callback(callback)
		return callback.event_loop:add_task(callback.task)
	end

	--[[@
		@name sleep
		@desc This function pauses the current task execution and resumes it after some time.
		@param delay<number> The time to sleep
	]]
	function EventLoop:sleep(delay)
		self:call_soon(delay, self.current_task, true)
		return self:stop_task_execution()
	end

	--[[@
		@name call_soon
		@desc This function appends the given task to the EventLoop list after some time.
		@param delay<number> The time to wait until the task can be appended
		@param task<Task> The task to append
		@param no_future?<boolean> Either to cancel the creation or not a Future object that will return after the task ends. Defaults to false.
		@returns Future Returns the Future object if no_future is false.
	]]
	function EventLoop:call_soon(delay, task, no_future)
		return self:schedule(time() + delay, task, no_future)
	end

	--[[@
		@name sleep_until
		@desc The same as EventLoop:sleep, but with an absolute time.
		@param when<number> The time when the task will be resumed
	]]
	function EventLoop:sleep_until(when)
		self:schedule(when, self.current_task, true)
		return self:stop_task_execution()
	end

	--[[@
		@name schedule
		@desc The same as EventLoop:call_soon, but with an absolute time.
		@param when<number> The time when the task can be appended
		@param task<Task> The task to append
		@param no_future?<boolean> Either to cancel the creation or not a Future object that will return after the task ends. Defaults to false.
		@returns Future Returns the Future object if no_future is false.
	]]
	function EventLoop:schedule(when, task, no_future)
		self.timers:add {
			callback = self.timers_callback,
			when = when or 0,
			task = task,
			event_loop = self
		}

		if not no_future then
			local future = self:new_future()
			task:add_future(future)
			return future
		end
	end

	--[[@
		@name add_task
		@desc Adds a task to run on the next loop iteration.
		@param task<Task> The task to append
	]]
	function EventLoop:add_task(task)
		self.tasks_index = self.tasks_index + 1
		self.tasks[self.tasks_index] = task
	end

	--[[@
		@name new_future
		@desc Creates a new Future object that belongs to this EventLoop
		@returns Future The Future object
	]]
	function EventLoop:new_future()
		return Future.new(self)
	end

	--[[@
		@name new_future_semaphore
		@desc Creates a new FutureSemaphore object that belongs to this EventLoop
		@returns FutureSemaphore The FutureSemaphore object
	]]
	function EventLoop:new_future_semaphore(quantity)
		return FutureSemaphore.new(self, quantity)
	end

	--[[@
		@name stop_task_execution
		@desc Pauses the task execution. This can be called from inside the task only.
		@desc /!\ The task doesn't resume again if you don't append it back later. If you don't do it, this will just stop forever the task execution.
	]]
	function EventLoop:stop_task_execution()
		self.current_task.paused = true
		return yield()
	end

	--[[@
		@name await
		@desc Awaits a Future or Task to complete. Pauses the current task and resumes it again once the awaitable is done.
		@param aw<Future|Task> The awaitable to wait.
		@returns mixed The Future or Task return values.
	]]
	function EventLoop:await(aw)
		if aw._is_future then
			-- if it is a future object it can't be appended to the task list _yet_
			aw._next_tasks_index = aw._next_tasks_index + 1
			aw._next_tasks[aw._next_tasks_index] = self.current_task
		else
			if aw.cancelled or aw.done then
				error("Can't await a cancelled or done task.", 2)
			end

			aw.paused = false
			aw._next_task = self.current_task
			self:add_task(aw)
		end
		return self:stop_task_execution()
	end

	--[[@
		@name await_many
		@desc Awaits many Tasks at once. Runs them concurrently, and requires a FutureSemaphore object to do so.
		@param ...<Tasks> The Tasks to await
		@returns table The table with all the Task returned values. Every index is in order and every index is a sub-table with the returned values.
	]]
	function EventLoop:await_many(...)
		local length = select("#", ...)
		local semaphore = self:new_future_semaphore(length)

		local task
		for index = 1, length do
			task = select(index, ...)
			task:add_future(semaphore, index)
			self:add_task(task)
		end

		return self:await(semaphore)
	end

	--[[@
		@name run
		@desc Runs a loop iteration.
	]]
	function EventLoop:run()
		self.timers:run()
		self:run_tasks()
		self:remove_tasks()
	end

	--[[@
		@name run_tasks
		@desc Runs the tasks in the list only.
	]]
	function EventLoop:run_tasks()
		local tasks, now, removed, task = self.tasks, time(), self.removed

		for index = 1, self.tasks_index do
			task = tasks[index]

			if not task.cancelled then
				self.current_task = task
				task:run(self)

				if task.cancelled or task.paused or task.done then
					task.paused = false
					self.removed_index = self.removed_index + 1
					removed[self.removed_index] = index
				end
			else
				self.removed_index = self.removed_index + 1
				removed[self.removed_index] = index
			end
		end

		self.current_task = nil
	end

	--[[@
		@name remove_tasks
		@desc Removes the tasks that are waiting to be removed from the list.
	]]
	function EventLoop:remove_tasks()
		local tasks, removed, remove = self.tasks, self.removed
		for index = 1, self.removed_index do
			remove = removed[index]

			if remove < self.tasks_index then
				tasks[remove] = tasks[self.tasks_index]
				-- tasks[self.tasks_index] = nil
			end

			self.tasks_index = self.tasks_index - 1
		end

		self.removed_index = 0
	end
end

local LimitedEventLoop
do
	local time = os.time

	LimitedEventLoop = setmetatable(
		{}, {__index = EventLoop}
	)
	local meta = {__index = LimitedEventLoop}

	--[[@
		@name new
		@desc Creates a new instance of LimitedEventLoop: the same as EventLoop but with runtime limitations
		@desc This inherits from EventLoop
		@param runtime<int> The maximum runtime that can be used.
		@param reset<int> How many time it needs to wait until the used runtime is resetted.
		@param obj?<table> The table to turn into an EventLoop.
		@returns LimitedEventLoop The LimitedEventLoop.
		@struct {
			timers = TimerList, -- A list of the timers the EventLoop will handle
			tasks = {}, -- The list of tasks the EventLoop is running
			removed = {}, -- The list of indexes in the tasks list to remove
			tasks_index = 0, -- The tasks list pointer
			removed_index = 0, -- The removed list pointer
			runtime = runtime, -- The maximum runtime
			reset = reset, -- The reset interval
			used = 0, -- The used runtime
			initialized = 0, -- When was the last runtime reset
			step = 0 -- The iteration step (0 -> needs to run timers, 1 -> needs to run tasks, 2 -> needs to remove tasks)
		}
	]]
	function LimitedEventLoop.new(runtime, reset, obj)
		obj = EventLoop.new(obj)
		obj.runtime = runtime
		obj.reset = reset
		obj.used = 0
		obj.initialized = 0
		obj.step = 0
		return setmetatable(obj, meta)
	end

	--[[@
		@name can_run
		@desc Checks if the EventLoop can run something.
		@param now<int> How many runtime is being used and not counted in LimitedEventLoop.used
		@returns boolean Whether it can run something or not
	]]
	function LimitedEventLoop:can_run(now)
		return self.used + now < self.runtime
	end

	--[[@
		@name run
		@desc Runs (or partially runs) a loop iteration if it is possible.
	]]
	function LimitedEventLoop:run()
		local start = time()

		if start - self.initialized >= self.reset then
			self.initialized = start
			self.used = 0
		end

		if self.step == 0 then
			if self:can_run(0) then
				self.timers:run()
				self.step = 1
			end
		end

		if self.step == 1 then
			if self:can_run(time() - start) then
				self:run_tasks()
				self.step = 2
			end
		end

		if self.step == 2 then
			if self:can_run(time() - start) then
				self:remove_tasks()
				self.step = 0
			end
		end

		self.used = self.used + time() - start
	end
end

return {
	EventLoop = EventLoop,
	LimitedEventLoop = LimitedEventLoop,
	Task = Task,
	TimerList = TimerList,
	Future = Future,
	FutureSemaphore = FutureSemaphore,

	async = async
}