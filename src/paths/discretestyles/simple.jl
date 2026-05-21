"""
    struct SimpleTraceCorner <: DiscreteStyle
"""
struct SimpleTraceCorner <: DiscreteStyle end
Base.copy(c::SimpleTraceCorner) = c
reverse(c::SimpleTraceCorner) = c
