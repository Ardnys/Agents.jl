# # Integrating Agents.jl with DelaunayTriangulation.jl

# ```@raw html
# <video width="auto" controls autoplay loop>
# <source src="../delaunay_model.mp4" type="video/mp4">
# </video>
# ```

# This example illustrates how to integrate Agents.jl with [DelaunayTriangulation.jl](https://github.com/JuliaGeometry/DelaunayTriangulation.jl),
# a Julia package for computing Delaunay triangulations and Voronoi tessellations in the plane. We consider 
# a model based on those discussed in the paper [_Comparing individual-based approaches to modelling the self-organization of multicellular tissues_](https://doi.org/10.1371/journal.pcbi.1005387)
# by Osborne et al. (2017); other models, such as weighted Delaunay triangulation models as discussed in [this paper](https://doi.org/10.1016/S0070-2153(07)81013-1),
# are possible but are not considered here. For mathematical details about Delaunay triangulations and Voronoi tessellations, see 
# the documentation for DelaunayTriangulation.jl. We emphasise that some parts of this example could be easily made 
# more performant, but that is not the purpose of this exercise.

# ## [The model](@id delaunay_model)
# The model we will be examining is a model of diffusion, proliferation, and death between 
# three interacting species of cells. 

# Let the cell species be labelled `R`, `B`, and `O`, standing for red, blue, and orange cells, respectively.
# To each cell we associate some position $\mathbf x_i(t)$. Given a collection of cell positions $\mathcal P(t) = \{\mathbf x_i(t)\}$,
# let $\mathcal V(\mathcal P(t))$ denote its Voronoi tessellation; to avoid issues with unbounded Voronoi cells on the boundary, 
# we will clip the Voronoi cells to the convex hull of the points, $\mathcal C\mathcal H(\mathcal P(t))$; i.e., we are considering
# $\mathcal V(\mathcal P(t)) \cap \mathcal C\mathcal H(\mathcal P(t))$ rather than $\mathcal V(\mathcal P(t))$ itself. The Voronoi cell
# associated with the position $\mathbf x_i(t)$ is denoted $\mathcal V_i$, and it is $\mathcal V_i$ that we treat as the cell itself
# for the purpose of associating areas with cells. 

# ### [Diffusion](@id delaunay_model_diffusion)
# Now let's describe how the cells move in space and interact with eachother. We use a Hookean force law model 
# for describing the interactions between cells, so that 
# ```math
# \eta\dfrac{\mathrm d\mathbf x_i}{\mathrm dt} = \mathbf F_i(t) = \sum_{j \in \mathcal N_i(t)} \mathbf F_{ij}(t) + \mathbf F^{\textrm{rand}}_i(t),
# ```
# where $\eta$ is a damping constant, $\mathcal N_i(t)$ is the set of neighbours of $\mathbf x_i(t)$ at time $t$ in the 
# Delaunay triangulation $\mathcal D\mathcal T(\mathcal P(t))$, $\mathbf F_{ij}$ is the force on $\mathbf x_i$ due to $\mathbf x_j$, and 
# $\mathbf F^{\textrm{rand}}_i$ is a random force applied to $\mathbf x_i$. The interaction forces $\mathbf F_{ij}$ are given by 
# ```math
# \mathbf F_{ij}(t) = \mu_{ij}(t)\left(\|\mathbf x_{ij}\| - s_{ij}(t)\right)\hat{\mathbf x}_{ij},
# ```
# where $\mu_{ij}(t)$ is the spring constant, $s_{ij}(t)$ is the resting spring length, $\mathbf x_{ij} = \mathbf x_j - \mathbf x_i$,
# and $\hat{\mathbf x}_{ij} = \mathbf x_{ij}/\|\mathbf x_{ij}\|$. To avoid issues with unduly long edges between 
# cells along the boundary, whenever $\|\mathbf x_{ij}\| > \ell_{\max}$
# we prevent the cells from interacting and declare $\mathbf F_{ij} = \mathbf 0$. The spring constant is given by $\mu_{ij} = \mu$ 
# when the cells interacting are of the same species, otherwise
# ```math 
# \mu_{ij}(t) = \begin{cases} \mu_{\textrm{het}}\mu & \|\mathbf x_{ij}\| > s_{ij}(t), \\ \mu & \|\mathbf x_{ij}\| \leq s_{ij}(t), \end{cases}
# ```
# where $\mu_{\textrm{het}}$ is a heterotypic spring constant factor used to promote adhesion between cells of different species
# that are further apart than their resting spring length. For $t < 1$ we use $\mu_{\textrm{het}} = 1$ 
# to prevent this adhesion for the initial population of cells. The resting spring length is allowed to grow
# over the first hour of each cell's life, so that 
# ```math
# s_{ij}(t) = \min\{s, (s - \varepsilon)t + \varepsilon\},
# ```
# where $\varepsilon$ is an expansion rate and $s$ is the mature resting spring length. With this definition,
# $s_{ij}(t)$ evolves from $\varepsilon$ to $s$ over the first hour of the cell's life, and remains at $s$ thereafter.
# The random force $\mathbf F^{\textrm{rand}}_i$ is given by 
# ```math
# \mathbf F^{\textrm{rand}}_i(t) = \sqrt{\frac{2\xi}{\Delta t}}(\eta_1, \eta_2),
# ```
# where $\xi$ is a diffusivity parameter, $\Delta t$ is the step size used in the simulation, 
# and $\eta_1$ and $\eta_2$ are independent standard normal random variables.

# To use these forces to evolve the cell positions, we use the forward Euler method to write 
# ```math
# \mathbf x_i(t + \Delta t) = \mathbf x_i(t) + \Delta t \dfrac{1}{\eta}\mathbf F_i(t).
# ```
# If this computed $\mathbf x_i(t + \Delta t)$ puts the cell position outside of some box $[a, b] \times [c, d]$,
# the step is rejected and the cell position remains at $\mathbf x_i(t)$. (Other choices such as restricting the 
# cell position to the box and only allowing it to slide along the boundary are possible, but are not considered here.)

# ### [Proliferation](@id delaunay_model_proliferation)
# Now we consider cell proliferation. Cells are assumed to only be allowed to proliferate if they are between 
# the ages $t_{\min}^k \leq t \leq t_{\max}^k$, where $k$ is the species of the cell so that the 
# ages are species-dependent. Cells are assumed to proliferate according to a logistic proliferation law,
# and at most one cell may proliferation over a given interval $[t, t + \Delta t)$ (meaning $\Delta t$
# should be chosen to be small enough that this is not an issue). Given that a cell does proliferate,
# the probability that it proliferates is given by $G_i^k\Delta t$, where 
# ```math 
# G_i^k = \max\left\{0, \beta^k\left(1 - \frac{1}{KA_i}\right)\right\},
# ```
# where $\beta^k$ is the intrinsic proliferation rate, $K$ is a cell carrying capacity density,
# and $A_i$ is the area of $\mathcal V_i$. Thus, the probability that any proliferation event occurs in 
# $[t, t+\Delta t)$ is given by $\sum_i G_i^k\Delta t$, where the sum is over all alive cells. When a 
# cell does proliferate, the daughter cell is placed at a random position in $\mathcal V_i$ and
# is inserted into the tessellation. We also assume that cells that are too small cannot proliferate,
# and set $G_i^k = 0$ whenever $A_i < A_{\min}$ for some minimum allowable area $A_{\min}$.

# When a cell proliferates, we allow for a mutation event to occur so that the daughter cell 
# is not necessarily of the same species as its parent. We define probabilities $p_{\textrm{mut}}^k$ for each 
# cell type, so that a red cell instead produces a blue cell with probability $p^R$, a blue cell 
# instead produces an orange cell with probability $p^B$, and an orange cell instead produces a red cell
# with probability $p^O$.

# ### [Death](@id delaunay_model_death)
# The final component of the model is cell death. There are three possible ways for a cell to die. Firstly,
# it may be too old, in which case we simply kill the cell. These maximum ages are denoted $d_{\max}^k$
# for each species $k$. Secondly, a cell may get sick and die. For each cell over each time interval,
# there is a probability $p_{\textrm{sick}}^k\Delta t$ that it will die over that interval. Lastly,
# it may be outside of $[a, b] \times [c, d]$, in which case we kill the cell; this might only occur for 
# daughter cells randomly placed in $\mathcal V_i$ and is done for simplicity.

# ## [Implementation](@id delaunay_model_implementation)
# Let's now get into the details of the implementation. Let us start by defining our agent type. 
# The cell types are defined using an `@enum`.
using Agents, StaticArrays
@enum CellType begin
    Red
    Blue
    Orange
end
@agent struct Cell(ContinuousAgent{2,Float64})
    const color::CellType
    const birth::Float64
    death::Float64 = Inf
end

# ### [Model parameters](@id delaunay_model_parameters)

# To now actually use these agents, we need to have a definition for the `model_step!` function;
# we don't use `agent_step!` since it's simpler to do everything within `model_step!`. Defining `model_step!`
# requires us to first define all the other components.
#
# We need to make these agents compatible with the interface required for DelaunayTriangulation.jl
# so that we can directly provide `Cell`s into DelaunayTriangulation.jl. The functions we need 
# to conform to this interface are minimal.
using DelaunayTriangulation
const DT = DelaunayTriangulation
DT.getx(cell::Cell) = cell.pos[1]
DT.gety(cell::Cell) = cell.pos[2]
DT.number_type(::Type{Cell}) = Float64
DT.number_type(::Type{Vector{Cell}}) = Float64
DT.is_point2(::Cell) = true

# To define the model parameters such as $\mu$, we use functions. An alternative is to just pass these 
# as model parameters, but this is simpler for the purposes of this example.
spring_constant(p, q) = 20.0 # μ
heterotypic_spring_constant(p, q) = p.color == q.color ? 1.0 : 0.1 # μₕₑₜ
drag_coefficient(p) = 1 / 2 # η
mature_cell_spring_rest_length(p, q) = 1.0 # s
expansion_rate(p, q) = 0.05 * mature_cell_spring_rest_length(p, q) # ε
perturbation(p) = 0.01 # ξ
cutoff_distance(p, q) = 1.5 # ℓₘₐₓ
intrinsic_proliferation_rate(p) = p.color == Red ? 0.4 : p.color == Blue ? 0.5 : 0.8 # β
carrying_capacity_density(p) = 100.0^2 # K
min_division_age(p) = 1.0 # tₘᵢₙ
max_division_age(p) = p.color == Red ? 15.0 : p.color == Blue ? 20.0 : 3.0 # tₘₐₓ
max_age(p) = p.color == Red ? 10.0 : p.color == Blue ? 10.0 : 3.0 # dₘₐₓ
death_rate(p) = p.color == Red ? 0.001 : p.color == Blue ? 0.00005 : 0.0001 # psick
mutation_probability(p) = p.color == Red ? 0.3 : p.color == Blue ? 0.5 : 0.05 # pₘᵤₜ
min_area(p) = 1e-2 # Aₘᵢₙ

# Next, we need the functions that compute these parameters for a given time and for a given 
# pair of cells. In these functions, the `model` parameter is the `StandardABM` we will 
# define later.
using LinearAlgebra
spring_constant(model, i::Int, j::Int, t) = spring_constant(model, model[i], model[j], t)
function spring_constant(model, p, q, t)
    δ = norm(p.pos - q.pos)
    s = rest_length(model, p, q, t)
    μ = spring_constant(p, q)
    t < 1 && return μ # no adhesion for the initial population
    μₕₑₜ = heterotypic_spring_constant(p, q)
    if δ > s
        return μₕₑₜ * μ
    else
        return μ
    end
end

rest_length(model, i::Int, j::Int, t) = rest_length(model, model[i], model[j]..., t)
function rest_length(model, p, q, t)
    s = mature_cell_spring_rest_length(p, q)
    ε = expansion_rate(p, q)
    return min(s, (s - ε) * t + ε)
end

function proliferation_rate(model, i::Int, t)
    p = model[i]
    age = t - p.birth
    tₘᵢₙ = min_division_age(p)
    tₘₐₓ = max_division_age(p)
    A = get_area(model.tessellation, i)
    if age ≤ tₘᵢₙ || age ≥ tₘₐₓ || A < min_area(p)
        return 0.0
    end
    vorn = model.tessellation
    Aᵢ = get_area(vorn, i)
    β = intrinsic_proliferation_rate(p)
    K = carrying_capacity_density(p)
    return max(0.0, β * (1 - 1 / (K * Aᵢ)))
end

# Now we need the function that computes the total force on a cell 
# at each time. 
force(model, i::Int, j::Int, t) = force(model, model[i], model[j], t)
function force(model, p, q, t)
    δ = norm(p.pos - q.pos)
    if δ > cutoff_distance(p, q)
        return SVector(0.0, 0.0)
    end
    μ = spring_constant(model, p, q, t)
    s = rest_length(model, p, q, t)
    rᵢⱼ = q.pos - p.pos
    return μ * (norm(rᵢⱼ) - s) * rᵢⱼ / norm(rᵢⱼ)
end
function random_force(model, i)
    p = model[i]
    ξ = perturbation(p)
    η₁, η₂ = randn(), randn()
    Δt = model.dt
    return sqrt(2ξ / Δt) * SVector(η₁, η₂)
end
function force(model, i::Int, t)
    F = SVector(0.0, 0.0)
    for j in get_neighbours(model.triangulation, i)
        DT.is_ghost_vertex(j) && continue
        F = F + force(model, i, j, t)
    end
    F = F + random_force(model, i)
    return F
end

# In the last `force` function, the check for `is_ghost_vertex` is needed since DelaunayTriangulation.jl 
# stores _ghost vertices_ in the triangulation for representing boundary information; 
# see [the documentation for DelaunayTriangulation.jl](https://juliageometry.github.io/DelaunayTriangulation.jl/stable/manual/ghost_triangles/).
# Note also that this `force` is not the velocity of the cell itself, but the force acting on the cell. 
# To get the velocity, we must divide by the drag coefficient.
velocity(model, i, t) = force(model, i, t) / drag_coefficient(model[i])

# ### [Implementing `model_step!`](@id delaunay_model_model_step)
# Migrating all the cells can now be done as follows. This is done in two stages,
# where we first compute the velocities and then move the cells. This is needed since,
# if we update the cell positions while updating the velocities, later cells 
# will not be correct as they will be computed using the updated positions. The 
# `each_solid_vertex` function iterates all over all the vertices in the triangulation,
# and thus the alive cells; the `solid` adjective is used to avoid iterating over
# the ghost vertices. (A more performant way to handle these updates would also be to 
# iterate over edges rather than vertices, but this is not considered here.)
function update_velocities!(model, t)
    for i in each_solid_vertex(model.triangulation)
        model[i].vel = velocity(model, i, t)
    end
    return model
end
function new_position(model, i, t)
    xᵢ = model[i]
    vel = xᵢ.vel
    r = xᵢ.pos + model.dt * vel
    x, y = r
    xmax, ymax = spacesize(model)
    if x < 0 || x > xmax || y < 0 || y > ymax
        r = xᵢ.pos
    end
    return r
end
function update_positions!(model, t)
    update_velocities!(model, t)
    for i in each_solid_vertex(model.triangulation)
        model[i].pos = new_position(model, i, t)
    end
    return model
end

# The next component to implement is proliferation. This will be a bit complicated since we need to 
# know how to sample from the Voronoi cell. Let's start by writing the function that allows us to 
# identify the Voronoi cell to proliferate. Since the proliferation probabilities are $G_i\Delta t$,
# we can build a vector that gives the cumulative sum of these probabilities; note that the last
# entry in this vector will be the sum of all the probabilities, and thus the probability that 
# any proliferation event occurs.
function proliferation_probability(model, t)
    Δt = model.dt
    probs = zeros(nagents(model)) # Technically nagents is not the number of alive agents, but with the way we are handling agents this is correct
    for i in allids(model)
        if !DT.has_vertex(model.triangulation, i) || i in model.dead_cells
            i > 1 && (probs[i] = probs[i-1])
            continue
        end
        Gᵢ = proliferation_rate(model, i, t)
        if i > 1
            probs[i] = probs[i-1] + Gᵢ * Δt
        else
            probs[i] = Gᵢ * Δt
        end
    end
    return probs
end
function select_proliferative_cell(model, probs)
    E = probs[end]
    u = rand() * E
    i = searchsortedlast(probs, u) + 1 # searchsortedlast instead of searchsortedfirst since we skip over some agents in probs
    return i
end

# Since we will not be clearing agents from the model, and instead only 
# marking them as dead, we use `has_vertex` on the triangulation rather than `hasid` on the model itself.
#
# Now let's write the function for sampling from a Voronoi cell. First, for sampling from a triangle,
# we use the algorithm from [this article](https://blogs.sas.com/content/iml/2020/10/19/random-points-in-triangle.html).
function sample_triangle(tri::Triangulation, T)
    i, j, k = triangle_vertices(T)
    p, q, r = get_point(tri, i, j, k)
    px, py = getxy(p)
    qx, qy = getxy(q)
    rx, ry = getxy(r)
    a = (qx - px, qy - py)
    b = (rx - px, ry - py)
    u₁, u₂ = rand(), rand()
    if u₁ + u₂ > 1
        u₁, u₂ = 1 - u₁, 1 - u₂
    end
    ax, ay = getxy(a)
    bx, by = getxy(b)
    wx, wy = u₁ * ax + u₂ * bx, u₁ * ay + u₂ * by
    return SVector(px + wx, py + wy)
end

# Next, we need to know how to select a random triangle from a triangulation. This is done by using a weighted 
# sample according to the triangle areas.
using StreamSampling
function random_triangle(tri::Triangulation)
    triangles = DT.each_solid_triangle(tri)
    area(T) = DT.triangle_area(get_point(tri, triangle_vertices(T)...)...)
    T = itsample(triangles, area)
    return T
end

# With these functions, sampling from a Voronoi cell is simple: First, triangulate the Voronoi cell.
# Then, sample a triangle from the triangulation, and finally sample a point from the triangle.
# The `triangulate_convex` function can efficiently triangulate the Voronoi cell, remembering that 
# Voronoi cells are convex.
function triangulate_voronoi_cell(vorn::VoronoiTessellation, i)
    S = @view get_polygon(vorn, i)[1:end-1]
    points = DT.get_polygon_points(vorn)
    return triangulate_convex(points, S)
end
function sample_voronoi_cell(vorn::VoronoiTessellation, i)
    tri = triangulate_voronoi_cell(vorn, i)
    T = random_triangle(tri)
    return sample_triangle(tri, T)
end

# We can now finally write the functions for computing the daughter cell and performing the proliferation
# event.
function place_daughter_cell!(model, i, t)
    parent = model[i]
    daughter = sample_voronoi_cell(model.tessellation, i) # this is an SVector, not a Cell
    u = rand()
    clr = parent.color
    if u < mutation_probability(parent)
        newclr = clr == Red ? Blue : clr == Blue ? Orange : Red
    else
        newclr = clr
    end
    add_agent!(daughter, model; color=newclr, birth=t, vel=SVector(0.0, 0.0))
    return daughter
end
function proliferate_cells!(model, t)
    probs = proliferation_probability(model, t)
    u = rand()
    event = u < probs[end]
    !event && return false
    i = select_proliferative_cell(model, probs)
    daughter = place_daughter_cell!(model, i, t)
    return true
end

# Next, we need the functions for cell death. This is much simpler. Rather than deleting the 
# agents directly, we only mark them as dead.
function cull_cell!(model, i, t)
    p = model[i]
    elder = t - p.birth > max_age(p)
    sick = rand() < model.dt * death_rate(p)
    xmax, ymax = spacesize(model)
    x, y = p.pos
    outside = x < 0 || x > xmax || y < 0 || y > ymax
    if elder || sick || outside
        push!(model.dead_cells, i)
        p.death = t
    end
    return model
end
function cull_cells!(model, t)
    for i in each_solid_vertex(model.triangulation)
        cull_cell!(model, i, t)
    end
    return model
end

# We are finally in a position to define `model_step!`. In this function, 
# for updating the Delaunay triangulation and the Voronoi tessellation,
# we simply recompute them from scratch. There could be more performant ways to do this,
# such as with [Shewchuk's star-splaying algorithm](https://doi.org/10.1145/1064092.1064129)
# for recomputing the triangulation efficiently from the previous one, but we keep it simple here.
function model_step!(model)
    stepn = abmtime(model)
    t = stepn * model.dt
    cull_cells!(model, t)
    proliferate_cells!(model, t)
    update_positions!(model, t)
    model.triangulation = retriangulate(model.triangulation, allagents(model); skip_points=model.dead_cells)
    model.tessellation = voronoi(model.triangulation, clip=true)
    return model
end

# ### [Initialising the model](@id delaunay_model_initialisation)
# Now with `model_step!` implemented, we are ready to actually work with our model. To start, 
# we need a function that initialises our model. The initial population of cells 
# is defined by placing random red cells in a circle centred at the centre of the box. The box $[a, b] \times [c, d]$
# is defined by the `sides` parameter, defaulting to $[0, 20] \times [0, 20]$. In this function,
# for type reasons, we pass to `triangulate` a vector of `Cell`s, rather than a vector of 
# `SVector`s. This means we need a bit of duplication with `add_agent!` since `StandardABM`
# accepts the agent type rather than the agents themselves.
using Random
function initialize_cell_model(;
    ninit=50,
    radius=2.0,
    dt=0.01,
    sides=SVector(20.0, 20.0))
    Random.seed!(0)
    ## Generate the initial random positions
    cent = SVector(sides[1] / 2, sides[2] / 2)
    cells = map(1:ninit) do i
        θ = 2π * rand()
        r = radius * sqrt(rand())
        pos = cent + SVector(r * cos(θ), r * sin(θ))
        cell = Cell(; id=i, pos=pos,
            color=Red, birth=0.0, vel=SVector(0.0, 0.0))
    end
    positions = [cell.pos for cell in cells]

    ## Compute the triangulation and the tessellation 
    triangulation = triangulate(cells)
    tessellation = voronoi(triangulation, clip=true)

    ## Define the model parameters 
    properties = Dict(
        :triangulation => triangulation,
        :tessellation => tessellation,
        :dt => dt,
        :dead_cells => Set{Int}()
    )

    ## Define the space
    space = ContinuousSpace(sides; periodic=false)

    ## Define the model 
    model = StandardABM(Cell, space; model_step!, properties, container=Vector)

    ## Add the agents
    for (id, pos) in pairs(positions)
        add_agent!(pos, model; color=Red, birth=0.0, vel=SVector(0.0, 0.0))
    end

    return model
end

# ## [Running the model](@id delaunay_model_running)
# Let's define the data collection functions. To avoid collecting to much data, we 
# avoid collecting any data on the agents themselves, and only consider model-level data.
# We want a function to count the number of cell types.
function count_cell_type(model, type)
    stepn = abmtime(model)
    t = stepn * model.dt
    n = 0
    for i in each_solid_vertex(model.triangulation)
        n += model[i].color == type
    end
    return n
end
count_red(model) = count_cell_type(model, Red)
count_blue(model) = count_cell_type(model, Blue)
count_orange(model) = count_cell_type(model, Orange)
count_total(model) = num_solid_vertices(model.triangulation)

# Let's also compute the average cell area and diameter, where 
# the diameter of a cell is defined as the length of the longest
# line segment between any two vertices of the cell. We also 
# consider the average spring length, i.e. the average length 
# of the edges in the Delaunay triangulation.
using StatsBase
function average_cell_area(model)
    area_itr = (get_area(model.tessellation, i) for i in each_solid_vertex(model.triangulation))
    mean_area = mean(area_itr)
    return mean_area
end
function cell_diameter(vorn, i)
    S = get_polygon(vorn, i)
    ## This is an O(|S|^2) method, but |S| is small so it is fine
    max_d = 0.0
    for i in S
        p = get_polygon_point(vorn, i)
        for j in S
            i == j && continue
            q = get_polygon_point(vorn, j)
            d = norm(getxy(p) .- getxy(q))
            max_d = max(max_d, d)
        end
    end
    return max_d
end
function average_cell_diameter(model)
    diam_itr = (cell_diameter(model.tessellation, i) for i in each_solid_vertex(model.triangulation))
    mean_diam = mean(diam_itr)
    return mean_diam
end
function average_spring_length(model)
    spring_itr = (norm(model[i].pos - model[j].pos) for (i, j) in each_solid_edge(model.triangulation))
    mean_spring = mean(spring_itr)
    return mean_spring
end

# Now let's simulate. We start by running the entire simulation and looking at the results.
finalT = 50.0
model = initialize_cell_model()
nsteps = Int(finalT / model.dt)
mdata = [count_red, count_blue, count_orange, count_total,
    average_cell_area, average_cell_diameter, average_spring_length]
agent_df, model_df = run!(model, nsteps; mdata);
#-

using CairoMakie
time = 0:model.dt:finalT
fig = Figure(fontsize=24)
ax = Axis(fig[1, 1], xlabel="Time", ylabel="Count", width=600, height=400)
lines!(ax, time, model_df[!, :count_red], color=:red, label="Red", linewidth=3)
lines!(ax, time, model_df[!, :count_blue], color=:blue, label="Blue", linewidth=3)
lines!(ax, time, model_df[!, :count_orange], color=:orange, label="Orange", linewidth=3)
lines!(ax, time, model_df[!, :count_total], color=:black, label="Total", linewidth=3)
axislegend(ax, position=:lt)
ax = Axis(fig[1, 2], xlabel="Time", ylabel="Average", width=600, height=400)
lines!(ax, time, model_df[!, :average_cell_area], color=:black, label="Cell area", linewidth=3)
lines!(ax, time, model_df[!, :average_cell_diameter], color=:magenta, label="Cell diameter", linewidth=3)
lines!(ax, time, model_df[!, :average_spring_length], color=:red, label="Spring length", linewidth=3)
axislegend(ax, position=:rb)
resize_to_layout!(fig)
fig

# Let's now animate the results. To visualise the results we make use of `abmplot`, which requires that we know how to make a marker
# for each agent. We define a function `voronoi_marker` that returns the vertices of the Voronoi cell
# associated with the agent, and a function `voronoi_color` that returns the color of the agent. Note that,
# when plotting polygons, `abmplot` internally assumes that the cells are positioned at the origin. Thus,
# when obtaining the Voronoi cells, we need to subtract the position of the cell from the vertices of the Voronoi cell. We 
# will show the data at each step during the animation as well, which requires a bit more complexity than just simply 
# using `abmvideo`. To avoid synchronisation issues, rather than using Makie.jl's `@lift` we use `Observable`s and update 
# them directly.
voronoi_marker = (model, cell) -> begin
    id = cell.id
    verts = get_polygon_coordinates(model.tessellation, id)
    return Makie.Polygon([Point2f(getxy(q) .- cell.pos) for q in verts])
end
voronoi_color(cell) = cell.color == Red ? :red : cell.color == Blue ? :blue : :orange
model = initialize_cell_model() # reinitialise the model for the animation
fig, ax, amobs = abmplot(model, agent_marker=cell -> voronoi_marker(model, cell), agent_color=voronoi_color,
    agentsplotkwargs=(strokewidth=1,), figure=(; size=(1600, 800), fontsize=34), mdata=mdata,
    axis=(; width=800, height=800), when=10)
current_time = Observable(0.0)
t = Observable([0.0])
nred = Observable(amobs.mdf[][!, :count_red])
nblue = Observable(amobs.mdf[][!, :count_blue])
norange = Observable(amobs.mdf[][!, :count_orange])
ntotal = Observable(amobs.mdf[][!, :count_total])
avg_area = Observable(amobs.mdf[][!, :average_cell_area])
avg_diam = Observable(amobs.mdf[][!, :average_cell_diameter])
avg_spring = Observable(amobs.mdf[][!, :average_spring_length])
plot_layout = fig[:, end+1] = GridLayout()
count_layout = plot_layout[1, 1] = GridLayout()
ax_count = Axis(count_layout[1, 1], xlabel="Time", ylabel="Count", width=600, height=400)
lines!(ax_count, t, nred, color=:red, label="Red", linewidth=3)
lines!(ax_count, t, nblue, color=:blue, label="Blue", linewidth=3)
lines!(ax_count, t, norange, color=:orange, label="Orange", linewidth=3)
lines!(ax_count, t, ntotal, color=:black, label="Total", linewidth=3)
vlines!(ax_count, current_time, color=:grey, linestyle=:dash, linewidth=3)
xlims!(ax_count, 0, finalT)
ylims!(ax_count, 0, 800)
avg_layout = plot_layout[2, 1] = GridLayout()
ax_avg = Axis(avg_layout[1, 1], xlabel="Time", ylabel="Average", width=600, height=400)
lines!(ax_avg, t, avg_area, color=:black, label="Cell area", linewidth=3)
lines!(ax_avg, t, avg_diam, color=:magenta, label="Cell diameter", linewidth=3)
lines!(ax_avg, t, avg_spring, color=:red, label="Spring length", linewidth=3)
vlines!(ax_avg, current_time, color=:grey, linestyle=:dash, linewidth=3)
axislegend(ax_avg, position=:rt)
xlims!(ax_avg, 0, finalT)
ylims!(ax_avg, 0, 2)
resize_to_layout!(fig)
on(amobs.mdf) do mdf
    current_time[] = abmtime(amobs.model[]) * model.dt
    t.val = mdf[!, :time] .* model.dt
    nred[] = mdf[!, :count_red]
    nblue[] = mdf[!, :count_blue]
    norange[] = mdf[!, :count_orange]
    ntotal[] = mdf[!, :count_total]
    avg_area[] = mdf[!, :average_cell_area]
    avg_diam[] = mdf[!, :average_cell_diameter]
    avg_spring[] = mdf[!, :average_spring_length]
end

# To now record, use `record` from Makie.
record(fig, "delaunay_model.mp4", 1:(nsteps ÷ 10), framerate=24) do i
    step!(amobs, 10)
end

# ```@raw html
# <video width="auto" controls autoplay loop>
# <source src="../delaunay_model.mp4" type="video/mp4">
# </video>
# ```
