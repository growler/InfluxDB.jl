__precompile__()
module InfluxDB

export InfluxServer, InfluxDB, create_db, query
import Base: write

using JSON
using Requests
using DataFrames
using Compat

# A server that we will be communicating with
immutable InfluxServer
    # HTTP API endpoints
    addr::URI

    # Optional authentication stuffage
    username::Nullable{AbstractString}
    password::Nullable{AbstractString}

    # Build a server object that we can use in queries from now on
    function InfluxServer(address::AbstractString; username=Nullable{AbstractString}(), password=Nullable{AbstractString}())
        # If there wasn't a schema defined (we only recognize http/https), default to http
        if !ismatch(r"^https?://", address)
            uri = URI("http://$address")
        else
            uri = URI(address)
        end

        # If we didn't get an explicit port, default to 8086
        if uri.port == 0
            uri =  URI(uri.scheme, uri.host, 8086, uri.path)
        end

        # URIs are the new hotness
        return new(uri, convert(Nullable{AbstractString}, username), convert(Nullable{AbstractString}, password))
    end

end

immutable InfluxDatabase
    server::InfluxServer
    name::AbstractString
end

# Add authentication to a query dict, if we need to
function authenticate!(server::InfluxServer, query::Dict)
    if !isnull(server.username) && !isnull(server.password)
        query["u"] = server.username.value
        query["p"] = server.password.value
    end
end

function query(db::InfluxDatabase, qs::AbstractString; chunk_size::Integer = 10000, chunked = false)

    query = Dict("db"=>db.name, "q"=>qs)
    authenticate!(db.server, query)
    if chunked then
        query["chunked"] = "true"
        query["chunk_size"] = string(chunk_size)
    end

    stream = get_streaming("$(db.server.addr)query"; query=query)
    if stream.response.status != 200
        error(bytestring(read(stream)))
    end

    ret = nothing
    while !eof(stream)
        jd = JSON.parse(stream)
        if jd == nothing then
            break
        end
        series_dict = jd["results"][1]["series"][1]
        df = DataFrame()
        for name_idx in 1:length(series_dict["columns"])
            df[symbol(series_dict["columns"][name_idx])] = [x[name_idx] for x in series_dict["values"]]
        end
        if ret == nothing then
            ret = df
        else 
            append!(ret, df)
        end
    end
    return ret
end

# Grab a timeseries
function query_series( server::InfluxServer, db::AbstractString, name::AbstractString;
                       chunk_size::Integer=10000)
    query = Dict("db"=>db, "q"=>"SELECT * from $name")

    authenticate!(server, query)
    response = get("$(server.addr)query"; query=query)
    if response.status != 200
        error(bytestring(response.data))
    end

    # Grab result, turn it into a dataframe
    series_dict = JSON.parse(bytestring(response.data))["results"][1]["series"][1]
    df = DataFrame()
    for name_idx in 1:length(series_dict["columns"])
       df[symbol(series_dict["columns"][name_idx])] = [x[name_idx] for x in series_dict["values"]]
    end
    return df
end

function use_db(server::InfluxServer, db::AbstractString) 
    InfluxDatabase(server, db)
end

# Create a database!
function create_db(server::InfluxServer, db::AbstractString)
    query = Dict("q"=>"CREATE DATABASE \"$db\"")

    authenticate!(server, query)
    response = get("$(server.addr)query"; query=query)
    if response.status != 200
        error(bytestring(response.data))
    else
	InfluxDatabase(server, db)
    end
end

function write( server::InfluxServer, db::AbstractString, name::AbstractString, values::Dict;
                            tags=Dict{AbstractString,AbstractString}(), timestamp::Float64=time())
    if isempty(values)
        throw(ArgumentError("Must provide at least one value!"))
    end

    # Start by building our query dict, pointing at a particular database and timestamp precision
    query = Dict("db"=>db, "precision"=>"s")

    # Next, string of tags, if we have any
    tagstring = join([",$key=$val" for (key, val) in tags])

    # Next, our values
    valuestring = join(["$key=$val" for (key, val) in values], ",")

    # Finally, convert timestamp to seconds
    timestring = "$(round(Int64,timestamp))"

    # Put them all together to get a data string
    datastr = "$(name)$(tagstring) $(valuestring) $(timestring)"

    # Authenticate ourselves, if we need to
    authenticate!(server, query)
    response = post("$(server.addr)write"; query=query, data=datastr)
    if response.status != 204
        error(bytestring(response.data))
    end
end

end # module
