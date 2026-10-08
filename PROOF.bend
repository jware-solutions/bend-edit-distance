import Base
import ./LAWS.bend as Laws

def Laws.empty_query(target):
  {==}

def Laws.empty_target(query):
  match query:
    case SNil{}:
      {==}
    case SCon{h, t}:
      {==}

def Laws.wildcard_padding(symbol):
  {==}

def Laws.distance_empty():
  {==}

def Laws.distance_match():
  {==}

def Laws.distance_substitution():
  {==}

def Laws.distance_deletion():
  {==}

def Laws.distance_insertion():
  {==}

def Laws.distance_example():
  {==}
