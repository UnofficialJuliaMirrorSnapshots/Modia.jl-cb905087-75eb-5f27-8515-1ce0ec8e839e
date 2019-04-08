"""
    module StateSelection

Functions to transform the ODAE generated by Pantelides to a special index-1 DAE 
using the static dummy derivative method with tearing to select dummy states and a 
generalization of the Gear-Gupta-Leimkuhler stabilization of multibody systems to handle
the remaining potential states (that would otherwise be treated with the dynamic
dummy derivative method). Details are described in the paper:

- Otter, Elmqvist (2017): **Transformation of Differential Algebraic Array Equations to 
  Index One Form**. Modelica'2017 Conference.


# Functions exported by this module:

- [`StateSelection.getSortedEquationGraph`](@ref): From Pantelides + BLT processed equations
  return the sorted equation graph (this includes static selection of states, and information
  to build up an implicit index 1 DAE in case dynamic state selection would be needed, 
  when transformed to ODE form).

- [`StateSelection.printSortedEquationGraph`](@ref): Print the result of
  [`StateSelection.getSortedEquationGraph`](@ref) in a human readable format.


# Main developer

[Martin Otter](https://rmc.dlr.de/sr/de/staff/martin.otter/), 
[DLR - Institute of System Dynamics and Control](https://www.dlr.de/sr/en)
"""
module StateSelection

# export SortedEquationGraph
# export getSortedEquationGraph!
export getSortedEquationGraph
export printSortedEquationGraph
# export newRaggedIntMatrix

include("Tearing.jl")
 
"""
    v = newRaggedIntMatrix(n)
    
Generate a new ragged int matrix with n rows and every row is initialized with a zero-sized Int vector.
"""
newRaggedIntMatrix(n) = [ fill(0, 0) for i = 1:n ]                  


"""
    Arev = revertAssociation(A,nArev)
    
Reverts the association Vector A[i] = j, such that Arev[j] = i (A[i]=0 is allowed and is ignored)
nArev is the dimension of Arev (nArev >= largest value of j appearing in A[i] = j).
"""
function revertAssociation(A::Vector{Int}, nArev::Int)::Vector{Int}
    Arev = fill(0, nArev)
    for i in eachindex(A)
        if A[i] != 0
            Arev[ A[i] ] = i
        end
    end
    return Arev
end


"""
    (eConstraints,vConstraints) = getConstraintSets(eBLT,Eassign,Arev,Brev)
    
Determines the set of constraint equations and their unknowns for BLT component eBLT.

Input arguments:

- `eBLT`: Vector of equation indices of BLT component c.
- `Eassign`: vc = Eassign(ec[i]) is variable vc assigned to equation ec[i].
- `Arev`: Reverted variable association: `Arev[i] = der(V[k]) == V[i] ? k : 0`.
- `Brev`: Reverted equation association: `Erev[i] = der(E[k]) == E[i] ? k : 0`. 

Output arguments:
- `eConstraints`: eConstraints[1] are the lowest-order, eConstraints[end-1] are the highest-order constraint equations 
   and eConstraints[end] = eBLT 
- `vConstraints`: vConstraints[i] are the unknowns of eConstraints[i].
"""
function getConstraintSets(eBLT::Vector{Int}, Eassign::Vector{Int}, Arev::Vector{Int}, Brev::Vector{Int})
    # Determine unknowns of BLT component c
    vBLT = fill(0, length(eBLT))
    for i in eachindex(eBLT)
        vBLT[i] = Eassign[eBLT[i]]
    end

    # Determine constraint sets
    eConstraints = [eBLT]
    vConstraints = [vBLT] 
    while true
        # Determine constraints at one differentiation order less
        ceq = fill(0, 0)
        for eq in eConstraints[1]
            if Brev[eq] > 0
                push!(ceq, Brev[eq])              
            end
        end
        if length(ceq) == 0; break; end
      
        @static if VERSION < v"0.7.0-DEV.2005"
            unshift!(eConstraints, ceq)   # move ceq to the beginning of the constraints vector
        else
            pushfirst!(eConstraints, ceq)   # move ceq to the beginning of the constraints vector
        end     
        # Determine unknowns of constraints at one differentiation order less
        veq = fill(0, 0)
      
        for vc in vConstraints[1]
            if Arev[vc] > 0
                push!(veq, Arev[vc])
            end
      
        end
        if length(veq) == 0;
            error("Error should not occur: eBLT equations and vBLT variables have different differentiation orders");
        end
      
        @static if VERSION < v"0.7.0-DEV.2005"
            unshift!(vConstraints, veq)   # move veq to the beginning of the constraints vector
        else
            pushfirst!(vConstraints, veq)   # move veq to the beginning of the constraints vector
        end
    end 

    @assert(length(eConstraints) == length(vConstraints))
    return (eConstraints, vConstraints)
end


"""
    eqInit = SortedEquationGraph(Gorigin,BLT,assign,A,B,VNames)
    
Initialize data structure to determine the sorted equation graph

Input arguments:

- `Gorigin`: `Gorigin[i]` is the vector of variable indices of equation `i`.
- `BLT`: `BLT[i]` is the vector of equations belonging to BLT-block `i`
- `assign`: `ei = assign[vi]` is equation `ei` assigned to variable `vi`
- `A`: A-Vector of Pantelides: `A[i] = if der(v[i]) == v[k] then k else 0` where `v[i]` is variable `i`. 
- `B`: B-Vector of Pantelides: `B[i] = if der(e[i]) == e[k] then k else 0` where `e[i]` is equation `i`.
- `VNames`: VNames[i] is the name of variable i (only used for potential debug and print output)

Output arguments:

- `eqInit`: Initialized data structure to determine the sorted equations.
            eqInit.Gunknowns is a subset of Gorigin that contains the variables
            of Gorigin that are treated as unknowns (e.g. used in tearing)

"""
mutable struct SortedEquationGraph
    first::Bool
    Gorigin::Vector{Any}            # Gorigin[i] is the vector of variable indices of equation i
    Gunknowns::Vector{Vector{Int}}  # Gunknowns[i] is the vector of variables of equation i that are treated as unknowns
    Gsolvable::Vector{Any}          # Gsolvable[i] contains the variables that can be
                                    # solved for equation i (used for tearing)
                                    # Gsolvable is only needed for the non-differentiated equations 
                                    # (tearing variables of differentiated equations are automatically decuded from 
                                    # the non-differentiated equations)
    eConstraintsVec::Vector{Vector{Vector{Int}}}   # ec = eConstraintsVec[i]: constraint sets of BLT block i; 
                                                   #      ec[1]  : lowest derivative equations
                                                   #      ec[end]: highest derivative equations (= BLT block i)
    vConstraintsVec::Vector{Vector{Vector{Int}}}   # vs = vConstraintsVec[i]: unknowns of ec
   
    assign::Vector{Int}         # ei = assign[vi] is equation ei assigned to variable vi
    A::Vector{Int}              # A-Vector of Pantelides
    B::Vector{Int}              # B-Vector of Pantelides
    VNames::Vector{String}      # VNames[i] is the name of variable i
   
    Arev::Vector{Int}           # Reverted vector A
    Brev::Vector{Int}           # Reverted vector B
    Eassign::Vector{Int}        # Reverted vector assign; vi = Eassign[ei] is equation ei assigned to variable vi
 
    isorted::Int                # The last element of ESorted that is defined
    irbeg::Int                  # The next element of the residue vector
    ESorted::Vector{Int}        # Sorted equations (equations must be generated in the order ESorted[1],[2],..)
    ESolved::Vector{Int}        # If ESolved[i] > 0 then equation ESorted[i] is explicitly solved for variable ESolved[i]
                               # If ESolved[i] < 0 then ESorted[i] is a residue equation to compute _r[ abs(ESolved[i]) ]
    rcat::Vector{Vector{Int}}
   
    Vx::Vector{Int}             # Variable j = Vx[i] is part of vector x; if j=0, this element of x is a dummy variable (not used)
    VxRev::Vector{Int}          # If VxRev[j] = i, then Vx[i] = j
                                # If VxRef[j] = 0, then variable j is not part of x
    Vderx::Vector{Int}          # Variable j = Vderx[i] is part of vector der_x; if j=0, this element of der_x is a dummy variable (not used)
    VderxRev::Vector{Int}       # If VderxRev[j] = i, then Vderx[i] = j
                                # If VderxRef[j] = 0, then variable j is not part of der_x   
    Vmue::Vector{Int}           # Equation j = Vmue[i] is the equation that is associated to mue[i] (mue[i] has the same sizes has equation j)

    td::TraverseDAG             # Holds information about tearing the equations
                               
    nc::Int                     # Number of residue constraints, so part that depends on (x,t) but not on der(x); 0 <= nc <= nx
    nmue::Int                   # Number of mue variables
    Er::Vector{Int}             # Equation j = Er[i] is part of residue vector r; if j=0, this element is part of ider0n2/ider1n1
    EAlgebraic::Vector{Bool}    # EAlgebraic[j] = true: equation j is an algebraic equation (cat = RA)
    VAlgebraic::Vector{Bool}    # VAlgebraic[j] = true: variable j is an algebraic variable (not a lambda variable)

   # The residue equation
   #   residue[1:nider] = der_x[ider0n2] - x[ider1n1]
   # must be added to the generated code
    ider0n2::Vector{Int}        # index vector der(0:n-2)
    ider1n1::Vector{Int}        # index vector der(1:n-1)
   
    function SortedEquationGraph(Gorigin, BLT, assign, A, B, VNames)
        @assert(length(assign) == length(VNames))
        @assert(length(A)      == length(VNames))
        @assert(length(B)      == length(Gorigin))
      
      # Revert association vectors
        Arev    = revertAssociation(A, length(A))
        Brev    = revertAssociation(B, length(B))
        Eassign = revertAssociation(assign, length(B))
    
      # Generate vectors with default elements
        ESorted = fill(0, 0)
        ESolved = fill(0, 0)
      
      # Residue vector structure
        rcat = newRaggedIntMatrix(6) 
      
      # Structure of x and der_x vectors
        Vx       = fill(0, 0)
        VxRev    = fill(0, length(VNames))
        Vderx    = fill(0, 0)
        VderxRev = fill(0, length(VNames))
        Vmue     = fill(0, 0)
      
      # Algebraic equations/variables
        EAlgebraic = fill(false, length(Gorigin))
        VAlgebraic = fill(false, length(VNames))
      
      # Determine equation/variable constraint sets from BLT
        Gunknowns = newRaggedIntMatrix(length(Gorigin))
        eConstraintsVec = Vector{Vector{Int}}[]
        vConstraintsVec = Vector{Vector{Int}}[]
        lowerDerivativeEquationsInBLT = false 
        c_ignore = false 

        for c in BLT 
         # Ignore block c if lower derivative equations
            c_ignore = false
            for ceq in c 
                if B[ceq] != 0 
                    lowerDerivativeEquationsInBLT = true 
                    c_ignore = true
                end 
            end

            if c_ignore
                continue
            end
    
         # Get all equation sets eConstraints and their corresponding unknowns vConstraints
         # from lowest to highest differentiation order (eConstraints[end] is c)
            (eConstraints, vConstraints) = getConstraintSets(c, Eassign, Arev, Brev)
         #println("... eConstraints = ", eConstraints)
         #println("... vConstraints = ", vConstraints)
            push!(eConstraintsVec, eConstraints)         
            push!(vConstraintsVec, vConstraints)
         
         # Construct Gunknowns
            for i in eachindex(eConstraints)
                for eq in eConstraints[i] 
                    Gunknowns[eq] = intersect(Gorigin[eq], vConstraints[i])
                end
            end
        end

        #if lowerDerivativeEquationsInBLT
        #    println("\n... Warning from SortedEquationGraph(..) (in StateSelection.jl):",
        #        "\n... BLT blocks with lower derivative equations have been ignored.\n")  
        #end 
      
      # Tearing information
        td = TraverseDAG(Gunknowns, length(VNames))
      
        new(true, Gorigin, Gunknowns, Any[], eConstraintsVec, vConstraintsVec, assign, A, B, VNames, Arev, Brev, Eassign, 0, 1, ESorted, ESolved,
          rcat, Vx, VxRev, Vderx, VderxRev, Vmue, td, 0, 0, fill(0, 0), EAlgebraic, VAlgebraic)
    end
end


"""
rCategorie:

- `RD`: Original, non-differentiated equation with derivative variables as unknowns and no constraints
- `RA`: Original, non-differentiated algebraic equation (only algebraic variables in the equation) and no constraints
- `RDER0`: Constraint equation that is not differentiated
- `RDER1`: Constraint equation is differentiated at least once, but not the highest derivative level
- `RDERN`: Constraint equation on highest derivative level
"""
@enum(rCategorie, RD = 1, RA, RDER0, RDER1, RDERN)

"""
    appendToSortedEquations!(eq,eSolved,vSolved,eResidue,vTear,highestDerivative)
    
Append eSolved and eResidue equations to sorted equations eq.ESorted,
store variables vSolved appropriatey, and store variables vTear in x or der_x vectors.
"""
function appendToSortedEquations!(eq::SortedEquationGraph, eSolved::Vector{Int}, vSolved::Vector{Int}, 
                                  eResidue::Vector{Int}, vTear::Vector{Int}, highestDerivative::Bool)
                                  
   # println("... highestDerivative = ", highestDerivative, ", eSolved = ", eSolved, ", vSolved = ", vSolved, ", 
   #          eResidue = ", eResidue, ", vTear = ", vTear)  
    cat::rCategorie = RD
   
   # Store solved equations in the right order in ESorted
    for i in eachindex(eSolved)
        push!(eq.ESorted, eSolved[i])
        vs = vSolved[i]

        if highestDerivative && eq.Brev[eSolved[i]] == 0 && eq.Arev[vs] > 0
         # Highest derivative equation, that is not differentiated and vs is a derivative
         # -> change solved equation to residue
            push!(eq.ESolved, 0)
            push!(eq.rcat[Int(RD)], length(eq.ESorted))    
            vsInt = eq.Arev[vs]
            if eq.VxRev[vsInt] == 0  
            # vsInt is not yet in x; store vsInt in x and vs in der_x
                push!(eq.Vx, vsInt)
                eq.VxRev[vsInt] = length(eq.Vx)
                push!(eq.Vderx, vs)
                eq.VderxRev[vs] = length(eq.Vderx)
            end            
        else         
         # Algebraic or constraint equation -> explicitly solved local equation
            push!(eq.ESolved, vs)
        end
    end

   # Store residue equations in ESorted
    for er in eResidue
        push!(eq.ESorted, er) 
        push!(eq.ESolved, 0)

        if highestDerivative
            if eq.EAlgebraic[er]
                cat = RA
            else
                cat = RD
            end
        else
            cat = eq.Brev[er] == 0 ? RDER0 : RDER1
        end
        push!(eq.rcat[Int((cat))], length(eq.ESorted))           

        if cat == RDER1
         # Define mue variable associated with equation er
            push!(eq.Vmue, er)
        end         
    end
   
   # Use tearing variables in x or in der_x-vector
    for vt in vTear
        if highestDerivative   
            # Highest derivative equation
            if eq.VAlgebraic[vt]
            # vt is an algebraic unknown -> vt is part of x
                push!(eq.Vx, vt)
                push!(eq.Vderx, 0)
                eq.VxRev[vt] = length(eq.Vx)            
            elseif eq.Arev[vt] == 0
            # vt is not a differentiated variable -> vt is part of lambda (so of der_x)
                push!(eq.Vx, 0)
                push!(eq.Vderx, vt)
                eq.VderxRev[vt] = length(eq.Vderx)
            else
            # vt is a differentiated variable -> Arev(vt) is part of x
                vtInt = eq.Arev[vt]
                if eq.VxRev[vtInt] == 0  # vtInt is not yet in x
                    push!(eq.Vx, vtInt)
                    eq.VxRev[vtInt] = length(eq.Vx)
                    push!(eq.Vderx, vt)
                    eq.VderxRev[vt] = length(eq.Vderx)
                end
            end
        else
         # Lower derivative constraint equation
            push!(eq.Vx, vt)
            eq.VxRev[vt] = length(eq.Vx)
            der_vt = eq.A[vt]
            if der_vt != 0 && eq.A[der_vt] == 0
            # der(vt) is highest derivative variable
                push!(eq.Vderx, der_vt)
                eq.VderxRev[vt] = length(eq.Vderx)
            else
            # der(vt) is not highest derivative variable
                push!(eq.Vderx, 0)         
            end
        end
    end

end
         

"""
    determineAlgebraicProperty!(eq, ec)
    
Determine whether all equations ec contain only algebraic variables.
If yes, mark this in eq.EAlgebraic and eq.VAlgebraic
"""
function determineAlgebraicProperty!(eq::SortedEquationGraph, ec::Vector{Int})
    if length(ec) == 0
        error("... Internal error in checkAlgebraicProperty!(..) in StateSelection.jl: length(ec) = 0")
    end
   
    for eci in ec                  # for all equations in ec
        for vci in eq.Gorigin[eci]  # for all variables in equation eci = ec[i]
            if eq.A[vci] > 0 || eq.Arev[vci] > 0
               # vci is not an algebraic variable
                return nothing
            end
        end
    end
   
    # ec is a set of algebraic variables with algebraic unknowns
    for eci in ec
        eq.EAlgebraic[eci] = true
        for vci in eq.Gorigin[eci]
            eq.VAlgebraic[vci] = true
        end
    end
    return nothing
end

isAlgebraic(v::Int, A::Vector{Int}, Arev::Vector{Int}) = A[v] == 0 && Arev[v] == 0

         
function deduceHigher(vLower::Vector{Int}, A)
    v = fill(0, length(vLower))
    for i in eachindex(vLower)
        derv = A[ vLower[i] ]
        if derv == 0
            error("... Internal error in StateSelection.jl: vLower/eLower = ", vLower[i], " has no derivative.")
        end
        v[i] = derv
    end
    return v
end


"""
    sortedEquationGraph = getSortedEquationGraph(Gorigin,Gsolvable,BLT,assign,A,B,VNames; 
                                                 withStabilization=true)
    
Return the sorted equation graph with selection of states and dummy states.

# Input arguments
- `Gorigin`: Gorigin[i] is the vector of variable indices of equation i.
- `Gsolvable`: Gsolvable[i] is a subset of Gorigin[i] and contains the unknowns that can be explicitly solved for (used for tearing).
   Gsolvable is only needed for the non-differentiated equations (all differentiated equations j can have Gsolvable[j]=[])
- `BLT`: BLT[i] is the vector of equations belonging to BLT-block i
- `assign`: ei = assign[vi] is equation ei assigned to variable vi
- `A`: A-Vector of Pantelides: `A[i] = if der(v[i]) == v[k] then k else 0` where `v[i]` is variable `i`. 
- `B`: B-Vector of Pantelides: `B[i] = if der(e[i]) == e[k] then k else 0` where `e[i]` is equation `i`.
- `VNames`: VNames[i] is the name of variable i (only used for potential debug and print output)
- `withStabilization`: An error is triggered if the DAE requires stabilization and `withStabilization=false`.

# Output arguments in sortedEquationGraph
- `Vx      `: Variable j = Vx[i] is part of vector x; if j=0, this element of x is a dummy variable (do not use in model code).
- `VxRev   `: If VxRev[j] = i, then Vx[i] = j; if VxRef[j] = 0, then variable j is not part of x.
- `Vderx   `: Variable j = Vderx[i] is part of vector der_x; if j=0, this element of der_x is a dummy variable (not used).
- `VderxRev`: If VderxRev[j] = i, then Vderx[i] = j. If VderxRef[j] = 0, then variable j is not part of der_x.
- `Er      `: Equation j = Er[i] is part of residue vector r; if j=0, this element is part of ider0n2/ider1n1
- `ider0n2 `: Index vector, such that _residue[1:length(ider0n2)] = _der_x[ider0n2] - _x[ider1n1].
- `ider1n1 `: Index vector, such that _residue[1:length(ider0n2)] = _der_x[ider0n2] - _x[ider1n1].
- `ESorted `: Sorted equations (equations must be generated in the order ESorted[1],[2],..).              
- `ESolved `: If ESolved[i] > 0 then equation ESorted[i] is explicitly solved for variable ESolved[i].
              If ESolved[i] < 0, abs(ESolved[i]) is the index of the residue, so _residue[ abs(ESolved[i]) ] = residue of equation i.
- `nc      `: Number of residue constraints, so part that depends on (x,t) but not on der(x); 0 <= nc <= nx
- `nmue    `: Number of mue variables  
"""
function getSortedEquationGraph(G, Gsolvable, BLT, assign, A, B, VNames; withStabilization::Bool=true)
    eqInit = StateSelection.SortedEquationGraph(G, BLT, assign, A, B, VNames)
    eq = getSortedEquationGraph!(eqInit, Gsolvable)
    #printSortedEquationGraph(eq; equations=false)
    #println("\n")

    if !withStabilization
        # Check whether lambda and/or mue variables are present
#=
        lambdaVariables = String[]
        for i in eachindex(eq.Vx)
            vx = eq.Vx[i]
            if vx == 0
                # integral of lambda variable
                v_lambda = eq.Vderx[i]
                push!(lambdaVariables, eq.VNames[v_lambda])
            end
        end

        if length(lambdaVariables) > 0 || eq.nmue > 0
            # Code generator not prepared to handle DAE stabilization -> Trigger error
            printSortedEquationGraph(eq; equations=false)

            constraintVariables = String[]             
            for i in eq.ider1n1
                vc = eq.Vx[ eq.VxRev[ i ] ]
                push!(constraintVariables, eq.VNames[ vc ])
            end

            if length(lambdaVariables) > 0
                error("\n... Automatic state selection is not possible, because the code generator does not\n",
                      "    yet support DAE stabilization of higher index systems.\n",
                      "    Number of lambda variables: ", length(lambdaVariables), ", number of mue variables: ", eq.nmue, "\n",
                      "    The following (lambda) variables are the reason: ", lambdaVariables, ".")
            elseif eq.nmue > 0
                error("\n... Automatic state selection is not possible, because the code generator does not\n",
                      "    yet support the generation of stabilizing equations.\n",
                      "    Number of lambda variables: ", length(lambdaVariables), ", number of mue variables: ", eq.nmue, "\n",
                      "    The following (state) variables are the reason: ", constraintVariables, ".")      
            end
        end
=#
        if eq.nmue > 0
            # Code generator not prepared to handle DAE stabilization -> Trigger error
            printSortedEquationGraph(eq; equations=false)

            constraintVariables = String[]             
            for i in eq.ider1n1
                vc = eq.Vx[ eq.VxRev[ i ] ]
                push!(constraintVariables, eq.VNames[ vc ])
            end
            error("\n... Automatic state selection is not possible, because the code generator does not\n",
                  "    yet support the generation of stabilizing equations.\n",
                  "    Number of mue variables: ", eq.nmue, "\n",
                  "    The following (state) variables are the reason: ", constraintVariables, ".")      
        end

        # Determine differentiated variables in the original equations that are no states (dummy states)
    end
    return eq
end



"""
    sortedEquationGraph = getSortedEquationGraph(eqInit::SortedEquationGraph,Gsolvable)
    
Constructs all information for the sorted equation graph.

Input arguments:

- `eqInit`: Initialized data structure instantiated with SortedEquationGraph()
- `Gsolvable`: Subset of eqInit.Gunknowns that contains the unknowns that can be solved for (used for tearing).
   Gsolvable is only needed for the non-differentiated equations (all differentiated equations j can have Gsolvable[j]=[])

Output arguments in sortedEquationGraph:

- `Vx      `: Variable j = Vx[i] is part of vector x; if j=0, this element of x is a dummy variable (do not use in model code).
- `VxRev   `: If Vxrev[j] = i, then Vx[i] = j; if Vxref[j] = 0, then variable j is not part of x.
- `Vderx   `: Variable j = Vderx[i] is part of vector der_x; if j=0, this element of der_x is a dummy variable (not used).
- `VderxRev`: If VderxRev[j] = i, then Vderx[i] = j. If VderxRef[j] = 0, then variable j is not part of der_x.
- `Er      `: Equation j = Er[i] is part of residue vector r; if j=0, this element is part of ider0n2/ider1n1
- `ider0n2 `: Index vector, such that _residue[1:length(ider0n2)] = _der_x[ider0n2] - _x[ider1n1].
- `ider1n1 `: Index vector, such that _residue[1:length(ider0n2)] = _der_x[ider0n2] - _x[ider1n1].
- `ESorted `: Sorted equations (equations must be generated in the order ESorted[1],[2],..).              
- `ESolved `: If ESolved[i] > 0 then equation ESorted[i] is explicitly solved for variable ESolved[i].
              If ESolved[i] < 0, abs(ESolved[i]) is the index of the residue, so _residue[ abs(ESolved[i]) ] = residue of equation i.
- `nc      `: Number of residue constraints, so part that depends on (x,t) but not on der(x); 0 <= nc <= nx
- `nmue    `: Number of mue variables  
"""
function getSortedEquationGraph!(eq::SortedEquationGraph, Gsolvable)
    if !eq.first
        error("... getSortedEquationGraph(..) of StateSelection.jl is called twice with the same sortedEquationGraph object.\n",
            "    This is not possible. You need to instanciate SortedEquationGraph once for every getSortedEquationGraph(..) call.")
    else
        eq.first = false
    end

    eq.Gsolvable = Gsolvable
    td = eq.td      # tearing data structure
    eSolved  = Int[]
    vSolved  = Int[]
    eResidue = Int[]   
    vTear    = Int[]
    eSolvedFixedHighest  = Int[]
    vSolvedFixedHighest  = Int[]
    eResidueFixedHighest = Int[]
    vTearFixedHighest    = Int[]
    eConstraintsHighest  = Int[]
    vConstraintsHighest  = Int[]

    # Inspect every BLT component c in sequence 
    for j in eachindex(eq.eConstraintsVec)
        eConstraints = eq.eConstraintsVec[j]
        vConstraints = eq.vConstraintsVec[j]
      
       # Analyze all equation sets eConstraints from lowest-order to highest-order derivatives
        for i in eachindex(eConstraints)
            # println("... i = ", i, ", eConstraints[",i,"] = ", eConstraints[i], ", vConstraints = ", vConstraints[i])
            if i > 1
            # eConstraints[i] is the derivative of eConstraints[i-1] + potentially additional equations            
                eSolvedFixed = deduceHigher(eSolved, eq.B)
                vSolvedFixed = deduceHigher(vSolved, eq.A)
                vTearFixed   = deduceHigher(vTear, eq.A) 
            end
         
            if i == length(eConstraints)         
            # Highest derivative equations
                if i > 1 
                    # Part of the equations are differentiated
                    if length(eResidue) > 0
                        # Remove differentiated residues equations of eConstraints[i-1]) from the highest derivative equations
                        eResidueFixed = deduceHigher(eResidue, eq.B)
                        eConstraints[i] = setdiff(eConstraints[i], eResidueFixed)            
                    end
                    append!(eConstraintsHighest, eConstraints[i])
                    append!(vConstraintsHighest, vConstraints[i])
                    append!(eSolvedFixedHighest, eSolvedFixed)
                    append!(vSolvedFixedHighest, vSolvedFixed)               
                    append!(vTearFixedHighest, vTearFixed)    
                else
               # Original, undifferentiated equations
                    determineAlgebraicProperty!(eq, eConstraints[i])
                    append!(eConstraintsHighest, eConstraints[i])
                    append!(vConstraintsHighest, vConstraints[i])
                end
            
            else
                # Constraint equations, but not on highest level
                if i == 1
                    # Lowest derivative constraints
                    (eSolved, vSolved, eResidue, vTear) = tearEquations!(td, Gsolvable, eConstraints[i], vConstraints[i])            
                else
                    # Higher derivative constraint (but not highest level)
                    (eSolved, vSolved, eResidue, vTear) = tearEquations!(td, Gsolvable, eConstraints[i], vConstraints[i]; 
                                                                    eSolvedFixed=eSolvedFixed,
                                                                    vSolvedFixed=vSolvedFixed, 
                                                                    vTearFixed=vTearFixed)
                end
                appendToSortedEquations!(eq, eSolved, vSolved, eResidue, vTear, false)
            end
        end
    end
   
   # Tear equations on highest derivative level
    (eSolved, vSolved, eResidue, vTear) = tearEquations!(td, Gsolvable, eConstraintsHighest, vConstraintsHighest; 
                                                        eSolvedFixed=eSolvedFixedHighest,
                                                        vSolvedFixed=vSolvedFixedHighest,
                                                        vTearFixed=vTearFixedHighest)
   
   # Append equations to sorted equations
    appendToSortedEquations!(eq, eSolved, vSolved, eResidue, vTear, true)  
          
   # Determine index vectors ider0n2, ider1n1
    eq.ider0n2 = fill(0, 0)
    eq.ider1n1 = fill(0, 0)
    for vx in eq.Vx
        if vx > 0
            der_vx = eq.A[vx]
            
            if der_vx > 0 && eq.A[der_vx] > 0 
            # der(der(vx)) exists -> der(vx) is within x
                push!(eq.ider0n2, vx)
                push!(eq.ider1n1, der_vx)
            end
        end
    end
   
    eq.Er = fill(0, length(eq.ider0n2))
    append!(eq.Er, eq.rcat[Int(RD)])
    append!(eq.Er, eq.rcat[Int(RA)])
    append!(eq.Er, eq.rcat[Int(RDER0)])
    append!(eq.Er, eq.rcat[Int(RDER1)])

    for i = length(eq.ider0n2) + 1:length(eq.Er)
        eq.ESolved[ eq.Er[i] ] = -i
    end   

    eq.nc = length(eq.rcat[Int(RA)]) +
           length(eq.rcat[Int(RDER0)]) +
           length(eq.rcat[Int(RDER1)])

    eq.nmue = length(eq.Vmue)
           
    return eq
end


#============================ Functions for debugging/testing ================================#
"""
    Ader = derAssociation(A,N)
    
Determine derivatives of A[i] with respect to N base variables/equation
"""
function derAssociation(A, N)
   # Ader[i,1]: Base variable/equation
   # Ader[i,2]: Derivative of Base variable/equation
    Ader = [1:length(A) fill(0, length(A))]
    for i = 1:N
        der_v  = A[i]
        der_nr = 1
        while der_v > 0
            Ader[der_v,1] = i
            Ader[der_v,2] = der_nr
            der_nr += 1
            der_v  = A[der_v]
        end
    end
    return Ader
end


function printEquation(ec, Bder)
    der_nr = Bder[ec,2]
    if der_nr == 0  
        print("eq.", ec)
    else
        if der_nr == 1
            print("eq.", ec, " = der(eq.", Bder[ec,1], ")")
        else
            print("eq.", ec, " = der", der_nr, "(eq.", Bder[ec,1], ")")
        end
    end
    return nothing
end


"""
    printSortedEquationGraph(eq; equations=true)

Print information about the sorted equation graph.
If `equations = false`, the equations are not printed.
"""
function printSortedEquationGraph(eq::SortedEquationGraph; equations::Bool=true)  
   # Determine original number of equations (that are not differentiated)
    neqOrig = 0
    i = 0
    while i < length(eq.Brev)
        i += 1
        if eq.Brev[i] == 0
            neqOrig += 1
        else
            break
        end
    end
   
    # Build information about original equation derivatives
    Bder = derAssociation(eq.B, neqOrig)
   
    # Print variables stored in x vector
    println("\n  Variables of _x vector (length=", length(eq.Vx) + length(eq.Vmue), "):")
    for i in eachindex(eq.Vx)
        vx = eq.Vx[i]
        print("     _x[", i, "]: ")
        if vx != 0
            print(eq.VNames[vx])
            if isAlgebraic(vx, eq.A, eq.Arev)         
                print("      # algebraic variable")
            elseif eq.Arev[vx] > 0
                vxInt_index = eq.VxRev[ eq.Arev[vx] ]
                if vxInt_index != 0 
                    print("      # = der(_x[", vxInt_index, "])")
                else
                    print("      # error (integral ", eq.VNames[eq.Arev[vx]], " not stored in _x)")
                end
            end
        else
            print("---      # integral of lambda variable")
        end
        print("\n")      
    end
    nvx = length(eq.Vx)
    for i in eachindex(eq.Vmue)
        println("     _x[", nvx + i, "]: ---      # integral of mue variable")
    end

   
    # Print variables stored in der_x vector
    println("\n  Variables of _der_x vector (length=", length(eq.Vderx) + length(eq.Vmue), "):")
    for i in eachindex(eq.Vderx)
        vderx = eq.Vderx[i]
        print("     _der_x[", i, "]: ")
        if vderx != 0
            print(eq.VNames[vderx])
            if isAlgebraic(vderx, eq.A, eq.Arev)
                print("     # lambda variable")      
            end        
        else
            if isAlgebraic(eq.Vx[i], eq.A, eq.Arev)
                print("---      # derivative of algebraic variable")      
            else
                vx = eq.Vx[i]
                dervx = eq.A[vx]
                if dervx == 0
                    print("---      # error: vx = ", eq.VNames[vx], ", but der(vx) is not defined")
                else
                    der_vx_index = eq.VxRev[ dervx ]
                    if der_vx_index != 0 
                        print("---      # = _x[", der_vx_index, "] = ", eq.VNames[ eq.Vx[der_vx_index] ])
                    else
                        print("---      # error")
                    end
                end
            end
        end
        print("\n")
    end
    nvderx = length(eq.Vderx)
    for i in eachindex(eq.Vmue)
        emue = eq.Vmue[i]
        print("     _der_x[", nvderx + i, "]: ---      # mue variable associated with equation ")
        printEquation(emue, Bder)
        print("\n")
    end
   
    if !equations
        return
    end

    # Print sorted equations
    println("\n  Sorted equations (length(_r) = ", length(eq.Er), ", nc = ", eq.nc, "):")
    
    for i in eachindex(eq.ider0n2)
        iderx = eq.VxRev[ eq.ider0n2[i] ]
        ix    = eq.VxRev[ eq.ider1n1[i] ]
        println("     _r[", i, "]   = _der_x[", iderx, "] - _x[", ix, "]")
    end
    
    for i in eachindex(eq.ESorted)
        es = eq.ESorted[i]
        ev = eq.ESolved[i]
        if ev > 0  # local equation
            print("     ", eq.VNames[ev], "   = < solved from ")
        else # residue equation
            print("     _r[", -ev, "]   = < residue of ")
        end
        printEquation(es, Bder)
        print(" >\n")
    end
   
   # Raise error, if dimensions do not agree
    if length(eq.Vx) + length(eq.Vmue) != length(eq.Er)
        error("... length(_x) != length(_r)")
    end
    if eq.nc > length(eq.Er)
        error("... nc > length(Er)")
    end
   
end

end