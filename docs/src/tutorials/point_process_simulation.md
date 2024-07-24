# [Temporal Point Process (TPP) Simulation](@id tpp_tutorial)

JumpProcesses was initially developed to simulate the trajectory of jump
processes. Therefore, those with a background in point process might find
the nomenclature in the library documentation confusing. In reality, jump
and point processes share many things in common, but diverge in scope.
This tutorial will demonstrate how to simulate point processes using
JumpProcesses.

Historically, jump processes have been developed in the context of dynamical
systems to describe dynamics with sudden changes — the jumps — in a system's
value at random times. In contrast, the development of point processes has been
more focused on describing the occurrence of random events — the points — over
a support. The fact that any temporal point process (TPP) that satisfies some
basic assumptions can be described in terms of a stochastic differential
equation (SDE) with discontinuous jumps — more commonly known as a jump process
— means TPPs can be simulated with JumpProcesses.

Once you complete this tutorial, you might want to check our [advanced
tutorial on TPP](@ref tpp_advanced) that discusses more applications of
JumpProcesses to TPP.

## TPP Introduction

TPPs describe a set of discrete points over continuous time.
Conventionally, we assume that time starts at ``0``. We can represent
a TPP as a random integer measure ``N( \cdot )``. This random function
counts the number of points in a set of intervals over the real line. For
instance, ``N([5, 10])`` denotes the number of points (or events) in
between time ``5`` and ``10`` inclusive. The number of points in this
interval is a random variable.

For convenience, we denote ``N(t) \equiv N[0, t)`` as the number of points
since the start of time until ``t``, exclusive of ``t``. For simulation
purposes, ``N(t)`` will be the state of our system. In subsequent
sections, we will denote the state of the system as ``u(t) \equiv N(t)``
following SciML convention.

Any TPP can be characterized by its conditional intensity ``\lambda(t)``
which can be interpreted as the expected number of points per unit of
time. We assume ``N(t)`` changes according to the following dynamics on
any given infinitesimal unit of time.

```math
dN(t) = \begin{cases}
  1 \text{ , if } N[t, t + \epsilon] = 1 \\
  0 \text{ , if } N[t, t + \epsilon] = 0.
\end{cases}
```

It is possible to show that ``E(dN(t)) = \lambda(t) d(t)`` which
says that the expected number of points changes according to
``\lambda(t)`` over time. For this reason, ``\lambda(t)`` can also be
known as the rate of the TPP.

## Homogeneous Poisson Process

In this section, we specify a homogeneous Poisson process with unit rate,
which is the simplest TPP process with ``\lambda(t) = 1``. Let's start by
loading our packages.

```@example tpp-tutorial
using JumpProcesses, Plots
```

In JumpProcesses, a `ConstantRateJump` is a TPP whose rate is constant
between points. To specify the homogeneous Poisson process, we need to
declare the rate function which takes three inputs, the current state of
the system, `u`, the parameters, `p`, and the time, `t`. In this case, the
rate function is constant.

```@example tpp-tutorial
poisson_rate(u, p, t) = 1
```

We also need a function that updates the total count.

```@example tpp-tutorial
poisson_affect!(integrator) = (integrator.u[1] += 1)
```

Here, the convention is to take a [DifferentialEquations.jl
integrator](https://docs.sciml.ai/DiffEqDocs/stable/basics/integrator/),
and directly modify the current solution value it stores. i.e.,
`integrator.u` is the current solution vector, with `integrator.u[1]` the
first component of this vector.

Now, we can declare the Poisson process.

```@example tpp-tutorial
poisson_process = ConstantRateJump(poisson_rate, poisson_affect!)
```

Once we have declared the process we want to simulate, we need to specify
our simulation requirements. First, we determine the initial count and the
desired time span.

```@example tpp-tutorial
u0 = [0]
tspan = (0.0, 10.0)
```

We initialize a base problem containing our simulation specification.
Since we will not combine any other concurrent process with the Poisson
process, we create a `DiscreteProblem` which is the most basic problem for
simulating processes that evolve in discrete time steps as is the case
with our TPP.

```@example tpp-tutorial
dprob = DiscreteProblem(u0, tspan)
```

Apart from our base problem, we need to create a [`JumpProblem`](@ref) in which
we specify the simulation algorithm, i.e. the aggregator in JumpProcesses'
language, we intend to use for simulating the Poisson process. This aggregator
is responsible for sampling the times at which the process changes based on the
provided `poisson_rate` function, and for calling the user `poisson_affect!`
function to update the system state at these times. Here we use the `Direct`
method which is a type of thinning algorithm for simulating TPPs with a constant
rate between points.

```@example tpp-tutorial
jprob = JumpProblem(dprob, Direct(), poisson_process)
```

Finally, we can simulate one realization of our TPP. The solver requires that we
specify a time-stepper, which is a method that handles time-evolution in our
system. While the `Direct` algorithm above draws the next point in our process,
the stepper advances the system in time to that point. We use `SSAStepper` which
is a discrete stepper that only stops at the times proposed by our simulation
algorithm.

```@example tpp-tutorial
sol = solve(jprob, SSAStepper())
plot(sol)
```

By breaking the problem formulation and solver selection into specifying a
`DiscreteProblem`, a simulation algorithm (i.e. aggregator) via `JumpProblem`,
and generating a realization via `solve`, JumpProcesses' has the flexibility to
specify and simulate a broad variety of problem types. The base problem allow us
to combine TPPs with other types of dynamics such as ODEs or SDEs, by replacing
`DiscreteProblem` with `ODEProblem` or `SDEProblem` from
[DifferentialEquations.jl](https://docs.sciml.ai/DiffEqDocs/stable/). For
instance, we can declare a conditional intensity function that follows an ODE
using `ODEProblem`. The `JumpProblem` allows us to combine multiple TPPs
together as we will see in the next section. The simulation algorithm (i.e.
aggregator) allows us to simulate different types of TPPs including processes
with variable rates, using different algorithms that may offer improved
performance over `Direct` depending on the number of TPPs and their properties.
The time-stepper allow us to specify the time-evolution that allows the most
exotic dynamics to evolve in sync with base time.

## Multivariate TPPs

JumpProcesses allow us to simulate a multivariate TPP which is a TPP formed
by multiple TPPs whose rates can influence one another. In this section we
will illustrate a simple case with two TPPs. We assume that the first
process ``N_1`` is the homogeneous Poisson process from the previous
section. The second process ``N_2`` is a TPP whose intensity rate obeys
the following dynamics:

```math
\lambda_2(t) = \begin{cases}
  1 + \sin(t), & \text{if } N_1(t) \text{ is even} \\
  1 + \cos(t), & \text{if } N_1(t) \text{ is odd}.
\end{cases}
```

In this case, the intensity rate of the second process is variable. It not
only changes according to time but also according to the first process.

In JumpProcesses a `VariableRateJump` is a TPP whose rate is allowed to vary at
arbitrary times. Again, we start by declaring the rate function and the affect.

```@example tpp-tutorial
seasonal_rate(u, p, t) = 1 + (u[1] % 2 == 0 ? sin(t) : cos(t))
seasonal_affect!(integrator) = (integrator.u[2] += 1)
```

There are algorithms for simulating TPPs which can take
advantage of bounded variable rates. In our example, ``\lambda_2`` is
bounded above by ``2`` and below by ``1``. To initialize, a bounded
`VariableRateJump` we must supply the rate upper-bound and the
interval for which the upper-bound is valid. In this case, the bound is
valid throughout time. The lower-bound is optional but can improve the
speed of the simulation.

```@example tpp-tutorial
urate(u, p, t) = 2           # upper bound
rateinterval(u, p, t) = Inf  # time window bound is valid over
lrate(u, p, t) = 1           # lower bound
```

Now, we can declare the seasonal process as a `VariableRateJump`.

```@example tpp-tutorial
seasonal_process = VariableRateJump(seasonal_rate, seasonal_affect!;
    urate, rateinterval, lrate)
```

We initialize a new base problem with a different simulation
specification. Since we have a multivariate process, the state of the
system is a vector with two counts.

```@example tpp-tutorial
u0 = [0, 0]
tspan = (0.0, 10.0)
dprob = DiscreteProblem(u0, tspan)
```

We also need to modify [`JumpProblem`](@ref) to use a simulation algorithm (i.e.
aggregator) that supports bounded `VariableRateJump`s. In this case, we use the
`Coevolve` method, which is another type of thinning algorithm for multivariate
process and which is an improvement of the Ogata thinning method. This method
also requires a dependency graph that indicates for a given TPP which other TPPs
have rates that depend on states/variables altered in its affect function. Note
JumpProcesses' convention is that a given TPP should also always be a dependency
of itself. Internally, JumpProcesses preserves the relative ordering of point
processes of each distinct type, but always reorders all `ConstantRateJump`s to
appear before any `VariableRateJump`s. Irrespective of how `JumpProblem` is
initialized, internally the processes will be ordered as the vector
`[poisson_process, seasonal_process]` so that these will have the internal
indexes of `1` and `2` respectively. Note, this vector of the processes is
distinct from our state variable vector, `u`. When `poisson_process` fires
`u[1]` is altered, and as the rate for `seasonal_process` depends on it we have
that the dependencies of `poisson_process` are `[1,2]`. In contrast, the rate of
`poisson_process` is independent of `u[2]` which `seasonal_process` modifies,
and hence the dependencies of `seasonal_process` are only `[2]`.

Therefore, we obtain the following dependency graph:

```@example tpp-tutorial
dep_graph = [[1, 2], [2]]
```

We can then construct the corresponding problem `JumpProblem`, passing our
selected simulation algorithm, our processes and
the dependency graph.

```@example tpp-tutorial
jprob = JumpProblem(dprob, Coevolve(), poisson_process, seasonal_process; dep_graph)
sol = solve(jprob, SSAStepper())
plot(sol, labels = ["N_1(t)" "N_2(t)"], xlabel = "t", legend = :topleft)
```

## More TPPs

This tutorial demonstrated how to simulate simple TPPs. In addition to that,
JumpProcesses and the SciML ecosystem can be a powerful tool in describing more
general TPPs. We demonstrate this capability in the [advanced TPP tutorial](@ref
tpp_advanced), which shows how to interface JumpProcesses with
[PointProcesses.jl](https://github.com/gdalle/PointProcesses.jl) and covers via
this interface many different aspects usually studied in point process theory.
