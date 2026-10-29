import Base
import ./Sequence.bend as S
import ../EdlibTypes.bend as E
import ./Reconstruction.bend as R

# Myers owns nonempty distance and location searches. This module builds
# ordered results, preserves empty-input returns and validates reconstructed PATH.
type Location is Data:
  Location{end: E.Coordinate, start: Nat}

type Best is Data:
  Best{score: U32, locations: List<&2, Location>}

def update_best(best: Best, score: U32, location: Location, comparison: Cmp) -> Best:
  match best comparison:
    case Best{_, _} LT{}:
      Best{score, [location]}
    case Best{old, locations} EQ{}:
      Best{old, location <> locations}
    case _ GT{}:
      best

def ordered(best: Best) -> Best:
  match best:
    case Best{score, locations}:
      Best{score, List.reverse(&2, Location, locations)}

def ends.from(locations: List<&2, Location>, values: List<&2, E.Coordinate>) -> List<&2, E.Coordinate>:
  match locations:
    case Nil{}:
      List.reverse(&2, E.Coordinate, values)
    case Location{end, _} <> tail:
      ends.from(tail, end <> values)

def ends(locations: List<&2, Location>) -> List<&2, E.Coordinate>:
  ends.from(locations, Nil{})

def starts.from(locations: List<&2, Location>, values: List<&2, E.Coordinate>) -> List<&2, E.Coordinate>:
  match locations:
    case Nil{}:
      List.reverse(&2, E.Coordinate, values)
    case Location{_, start} <> tail:
      starts.from(tail, E.Position{start} <> values)

def starts(locations: List<&2, Location>) -> List<&2, E.Coordinate>:
  starts.from(locations, Nil{})

def span(target: String, location: Location) -> String:
  match location:
    case Location{E.BeforeStart{}, _}:
      ""
    case Location{E.Position{index}, start}:
      String.drop(String.take(target, 1n+index), start)

def path_result(score: U32, +locations: List<&2, Location>,
                +operations: List<&2, E.Operation>, format: E.CigarFormat) -> E.AlignResult:
  E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, ends(locations),
    Some{starts(locations)}, Some{operations}, Some{E.alignment_to_cigar(operations, format)}}

def location_valid(target: String, location: Location) -> Bool:
  match location:
    case Location{E.BeforeStart{}, start}:
      Nat.is_eq(start, 0n)
    case Location{E.Position{+end}, start}:
      Bool.and(Nat.is_lt(end, S.length(target)), Nat.is_le(start, 1n+end))

def path_checked(score: U32, locations: List<&2, Location>, format: E.CigarFormat,
                  operations: List<&2, E.Operation>, valid: Bool) -> E.AlignResult:
  match valid:
    case True{}:
      path_result(score, locations, operations, format)
    case False{}:
      E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}

def path_validate(query: String, segment: String, pairs: List<&2, E.EqualityPair>,
                   +score: U32, locations: List<&2, Location>, format: E.CigarFormat,
                   +operations: List<&2, E.Operation>, valid_location: Bool) -> E.AlignResult:
  path_checked(score, locations, format, operations,
    Bool.and(valid_location, R.valid_path(query, segment, operations, pairs, U32.to_nat(score))))

def path_reconstruct(+query: String, +segment: String, +pairs: List<&2, E.EqualityPair>,
                      +score: U32, locations: List<&2, Location>, format: E.CigarFormat,
                      valid_location: Bool) -> E.AlignResult:
  path_validate(query, segment, pairs, score, locations, format,
    R.reconstruct_known(query, segment, pairs, U32.to_nat(score)), valid_location)

def result(query: String, target: String, task: E.Task,
           pairs: List<&2, E.EqualityPair>, format: E.CigarFormat,
           best: Best, accepted: Bool) -> E.AlignResult:
  match task best accepted:
    case _ _ False{}:
      E.not_found()
    case E.Distance{} Best{score, locations} True{}:
      E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, ends(locations), None{}, None{}, None{}}
    case E.Locations{} Best{score, +locations} True{}:
      E.AlignResult{E.Ok{}, E.Found{U32.to_nat(score)}, ends(locations), Some{starts(locations)}, None{}, None{}}
    case E.Path{} Best{_, Nil{}} True{}:
      E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}
    case E.Path{} Best{score, +location <> tail} True{}:
      +sequence = target
      path_reconstruct(query, span(sequence, location), pairs, score,
        location <> tail, format, location_valid(sequence, location))

# Pinned Edlib returns before applying k or calculating starts/path on empty
# inputs, including PATH. Preserve that observable oracle behavior.
def empty_result(query: String, target: String, config: E.AlignConfig) -> E.AlignResult:
  match query target config:
    case SNil{} +t E.AlignConfig{E.NW{}, _, _, _, _}:
      +length = S.length(t)
      E.distance_result(length, E.end_coordinate(length), True{})
    case SNil{} _ _:
      E.distance_result(0n, E.BeforeStart{}, True{})
    case SCon{_, qt} SNil{} _:
      E.distance_result(1n+S.length(qt), E.BeforeStart{}, True{})
    # Internal precondition: Myers calls this only when one input is empty.
    case _ _ _:
      E.AlignResult{E.Error{}, E.NotFound{}, Nil{}, None{}, None{}, None{}}
