--!strict
const Window = require("./ReusableWindow")
const Geometry = require("./VirtualGeometry")

export type Snapshot = {
	Generation : number, Offset : number, First : number, Last : number,
	DataRevision : number, GeometryRevision : number,
}

const function New(Generation : number, Offset : number, First : number, Last : number,
	DataRevision : number?, GeometryRevision : number?) : Snapshot
	return {
		Generation = Generation, Offset = Offset, First = First, Last = Last,
		DataRevision = DataRevision or 1, GeometryRevision = GeometryRevision or 1,
	}
end

const function Covers(Front : Snapshot, Shape : Geometry.Geometry, Offset : number,
	DataRevision : number, GeometryRevision : number) : boolean
	return Front.DataRevision == DataRevision and Front.GeometryRevision == GeometryRevision
		and Window.Covers(Shape, Front.First, Front.Last, Offset)
end

const function Matches(Requested : Snapshot, Prepared : Snapshot) : boolean
	return Requested.Generation == Prepared.Generation and Requested.Offset == Prepared.Offset
		and Requested.First == Prepared.First and Requested.Last == Prepared.Last
		and Requested.DataRevision == Prepared.DataRevision
		and Requested.GeometryRevision == Prepared.GeometryRevision
end

return table.freeze({ New = New, Covers = Covers, Matches = Matches })
