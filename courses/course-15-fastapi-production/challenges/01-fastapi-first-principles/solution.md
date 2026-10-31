# Solution — FastAPI First Principles

Four targeted fixes to `main.py`. No structural rewrites needed.

```python
# main.py — repaired product catalog
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

app = FastAPI(title="Product Catalog")

_products: dict = {}
_next_id: int = 1


class ProductCreate(BaseModel):
    name: str
    category: str
    price: float = Field(gt=0)
    in_stock: bool = True


class Product(ProductCreate):
    id: int


@app.post("/products", status_code=201)           # fix 1: 201 Created
def create_product(body: ProductCreate) -> Product:  # fix 2: Pydantic model
    global _next_id
    product = Product(id=_next_id, **body.model_dump())
    _products[_next_id] = product
    _next_id += 1
    return product


@app.get("/products")
def list_products(in_stock: Optional[bool] = None) -> list[Product]:  # fix 3: Optional[bool]
    items = list(_products.values())
    if in_stock is not None:
        items = [i for i in items if i.in_stock == in_stock]
    return items


@app.get("/products/{product_id}")
def get_product(product_id: int) -> Product:
    if product_id not in _products:
        raise HTTPException(status_code=404, detail="product not found")  # fix 4
    return _products[product_id]
```

## Why each fix matters

**Fix 1: `status_code=201`.**
`POST` creating a resource must return 201 Created. Returning 200 forces every client to parse the body to decide whether a resource was created — status codes are the machine-readable contract.

**Fix 2: `ProductCreate(BaseModel)` with `Field(gt=0)`.**
A `dict` parameter bypasses Pydantic entirely. FastAPI can't validate the shape, so missing fields and invalid prices both return 200 with broken data. Adding `Field(gt=0)` to `price` and declaring the parameter as `ProductCreate` means FastAPI validates automatically and returns 422 before your function body runs.

**Fix 3: `Optional[bool]` on `in_stock`.**
`Optional[str]` stores the query string as-is. `?in_stock=true` arrives as the string `"true"`, and comparing it to the stored boolean `True` (`"true" == True` is `False` in Python) means the filter never matches. With `Optional[bool]`, FastAPI coerces `"true"` → `True` and `"false"` → `False` for you.

**Fix 4: `raise HTTPException(status_code=404)`.**
Returning `{"error": "not found"}` with status 200 is invisible to every monitoring tool and retry policy. `HTTPException(404)` makes the HTTP status code carry the error signal, which is what the rest of the stack (load balancers, APM agents, client SDKs) is built to read.

## Attacker's view

A 200 response that contains an error dict leaks internal state to an unauthenticated caller (the field names, the error wording). More dangerously, a 200 in a cache layer gets cached — the "not found" response is served to subsequent requests indefinitely. Returning the correct 4xx code ensures CDN and proxy caches never store error responses.
