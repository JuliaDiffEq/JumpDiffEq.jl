using DiffEqBase, JumpProcesses
using Test
const DJ = JumpProcesses

# test data
minpriority = 2.0^exponent(1e-12)
maxpriority = 2.0^exponent(1e12)
priorities = [1e-13, 0.99 * minpriority, minpriority, 1.01e-4, 1e-4, 5.0, 0.0, 1e10]

mingid = exponent(minpriority)   # = -40
ptog = priority -> DJ.priortogid(priority, mingid)
pt = DJ.PriorityTable(ptog, priorities, minpriority, maxpriority)

#display(priorities)
#display(pt)

# test insert
grpcnt = DJ.numgroups(pt)
push!(priorities, maxpriority * 0.99)
DJ.insert!(pt, length(priorities), priorities[end])
@test grpcnt == DJ.numgroups(pt)
@test pt.groups[end].pids[1] == length(priorities)

push!(priorities, maxpriority * 0.99999)
DJ.insert!(pt, length(priorities), priorities[end])
@test grpcnt == DJ.numgroups(pt)
@test pt.groups[end].pids[2] == length(priorities)

numsmall = length(pt.groups[2].pids)
push!(priorities, minpriority * 0.6)
DJ.insert!(pt, length(priorities), priorities[end])
@test grpcnt == DJ.numgroups(pt)
@test pt.groups[2].pids[end] == length(priorities)

push!(priorities, maxpriority)
DJ.insert!(pt, length(priorities), priorities[end])
@test grpcnt == DJ.numgroups(pt) - 1
@test pt.groups[end].pids[1] == length(priorities)

# test updating
DJ.update!(pt, 5, priorities[5], 2 * priorities[5])   # group 29
priorities[5] *= 2
@test pt.groups[29].numpids == 1
@test pt.groups[30].numpids == 1

DJ.update!(pt, 9, priorities[9], maxpriority * 1.01)
priorities[9] = maxpriority * 1.01
@test pt.groups[end].numpids == 2
@test pt.groups[end - 1].numpids == 1

DJ.update!(pt, 10, priorities[10], 0.0)
priorities[10] = 0.0
@test pt.groups[1].numpids == 2

# test sampling
cnt = 0
Nsamps = Int(1e7)
for i in 1:Nsamps
    global cnt
    pid = DJ.sample(pt, priorities)
    (pid == 8) && (cnt += 1)
end
@test abs(cnt // Nsamps - 0.008968535978248484) / 0.008968535978248484 < 0.05

##### PRIORITY TIME TABLE TESTS FOR CCNRM
mintime = 0.0;
maxtime = 100.0;
timestep = 1.5/16;
times = [2.0, 8.0, 13.0, 15.0, 74.0]

ptt = DJ.PriorityTimeTable(times, mintime, timestep)
@test DJ.getfirst(ptt) == (1, 2.0)
@test ptt.pidtogroup[5] == (0, 0) # Should not store the last one, outside the window.

# Test update
DJ.update!(ptt, 1, times[1], 10 * times[1]) # 2. -> 20., group 2 to group 14
@test ptt.groups[14].numpids == 1
@test DJ.getfirst(ptt) == (2, 8.0)
# Updating beyond the time window should not change the max priority. 
DJ.update!(ptt, 1, times[1], 70.0) # 20. -> 70.
@test ptt.groups[14].numpids == 0
@test ptt.maxtime == 66.0
@test ptt.pidtogroup[1] == (0, 0)

# Test rebuild
for i in 1:4
    DJ.update!(ptt, i, times[i], times[i] + 66.0)
end
@test DJ.getfirst(ptt) === (0, 0) # No more left.

mintime = 66.0;
timestep = 0.75;
DJ.rebuild!(ptt, mintime, timestep)
@test ptt.groups[11].numpids == 2 # 73.5-74.25
@test ptt.groups[18].numpids == 1
@test ptt.groups[21].numpids == 1
@test ptt.pidtogroup[1] == (0, 0)
