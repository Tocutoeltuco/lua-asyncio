local asyncio = require "asyncio"
local async = asyncio.async

-- You can use any of the EventLoop variants!
local loop = asyncio.loops.OrderedEventLoop.new()

local long_task = async(function()
	print("Start long_task")

	loop:sleep_until(0)
	-- basically waits for the next loop iteration

	print("Continue long_task")

	loop:sleep(10)
	-- If your os.time returns milliseconds, you might want to set a bigger value here

	print("End long_task")
end)

loop:add_task(long_task())
loop:add_task(asyncio.Task.new(function()
	print("Start small_task")
	loop:sleep_until(5)
	print("End small_task")
end, {}))

while true do
	loop:run()
end

--[[ OUTPUT OF THE PROGRAM:
Start long_task
Start small_task
Continue long_task
End small_task
End long_task
]]