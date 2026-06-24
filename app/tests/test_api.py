"""
Integration tests for Todo API endpoints
"""

import pytest
import json
from main import app


@pytest.fixture
def client():
    """Create a test client for the Flask app"""
    app.config['TESTING'] = True
    # Reset the todo_manager for each test
    from main import todo_manager
    todo_manager.todos = {}
    todo_manager.next_id = 1
    with app.test_client() as client:
        yield client


class TestAPIEndpoints:
    """Test cases for API endpoints"""
    
    def test_home_endpoint(self, client):
        """Test the home endpoint"""
        response = client.get('/')
        
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["message"] == "Welcome to Todo API"
        assert "endpoints" in data
    
    def test_health_check(self, client):
        """Test the health check endpoint"""
        response = client.get('/health')
        
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["status"] == "healthy"
        assert "timestamp" in data
    
    def test_get_todos_empty(self, client):
        """Test getting todos when none exist"""
        response = client.get('/api/todos')
        
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True
        assert data["count"] == 0
        assert data["data"] == []
    
    def test_create_todo_success(self, client):
        """Test creating a todo successfully"""
        payload = {
            "title": "Test Todo",
            "description": "Test Description"
        }
        response = client.post('/api/todos',
                              data=json.dumps(payload),
                              content_type='application/json')
        
        assert response.status_code == 201
        data = json.loads(response.data)
        assert data["success"] is True
        assert data["data"]["title"] == "Test Todo"
        assert data["data"]["description"] == "Test Description"
        assert data["data"]["id"] == 1
    
    def test_create_todo_without_description(self, client):
        """Test creating a todo without description"""
        payload = {
            "title": "Test Todo"
        }
        response = client.post('/api/todos',
                              data=json.dumps(payload),
                              content_type='application/json')
        
        assert response.status_code == 201
        data = json.loads(response.data)
        assert data["success"] is True
        assert data["data"]["title"] == "Test Todo"
        assert data["data"]["description"] == ""
    
    def test_create_todo_missing_title(self, client):
        """Test creating a todo without title returns 400"""
        payload = {
            "description": "Description only"
        }
        response = client.post('/api/todos',
                              data=json.dumps(payload),
                              content_type='application/json')
        
        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["success"] is False
        assert "error" in data
    
    def test_create_todo_no_data(self, client):
        """Test creating a todo with no data returns 400"""
        response = client.post('/api/todos',
                              content_type='application/json')
        
        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["success"] is False
    
    def test_get_todos_after_creating(self, client):
        """Test getting todos after creating some"""
        # Create todos
        client.post('/api/todos',
                   data=json.dumps({"title": "Todo 1"}),
                   content_type='application/json')
        client.post('/api/todos',
                   data=json.dumps({"title": "Todo 2"}),
                   content_type='application/json')
        
        # Get all todos
        response = client.get('/api/todos')
        
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True
        assert data["count"] == 2
        assert len(data["data"]) == 2
    
    def test_get_single_todo_success(self, client):
        """Test getting a specific todo"""
        # Create a todo
        create_response = client.post('/api/todos',
                                     data=json.dumps({"title": "Test Todo"}),
                                     content_type='application/json')
        created_data = json.loads(create_response.data)
        todo_id = created_data["data"]["id"]
        
        # Get the todo
        response = client.get(f'/api/todos/{todo_id}')
        
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True
        assert data["data"]["id"] == todo_id
        assert data["data"]["title"] == "Test Todo"
    
    def test_get_single_todo_not_found(self, client):
        """Test getting a non-existent todo returns 404"""
        response = client.get('/api/todos/999')
        
        assert response.status_code == 404
        data = json.loads(response.data)
        assert data["success"] is False
        assert "error" in data
    
    def test_update_todo_success(self, client):
        """Test updating a todo"""
        # Create a todo
        create_response = client.post('/api/todos',
                                     data=json.dumps({"title": "Original"}),
                                     content_type='application/json')
        created_data = json.loads(create_response.data)
        todo_id = created_data["data"]["id"]
        
        # Update the todo
        update_payload = {
            "title": "Updated Title",
            "description": "Updated Description",
            "completed": True
        }
        response = client.put(f'/api/todos/{todo_id}',
                             data=json.dumps(update_payload),
                             content_type='application/json')
        
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True
        assert data["data"]["title"] == "Updated Title"
        assert data["data"]["description"] == "Updated Description"
        assert data["data"]["completed"] is True
    
    def test_update_todo_not_found(self, client):
        """Test updating a non-existent todo returns 404"""
        payload = {"title": "New Title"}
        response = client.put('/api/todos/999',
                             data=json.dumps(payload),
                             content_type='application/json')
        
        assert response.status_code == 404
        data = json.loads(response.data)
        assert data["success"] is False
    
    def test_update_todo_no_data(self, client):
        """Test updating without data returns 400"""
        # Create a todo first
        create_response = client.post('/api/todos',
                                     data=json.dumps({"title": "Test"}),
                                     content_type='application/json')
        created_data = json.loads(create_response.data)
        todo_id = created_data["data"]["id"]
        
        # Try to update without data
        response = client.put(f'/api/todos/{todo_id}',
                             content_type='application/json')
        
        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["success"] is False
    
    def test_delete_todo_success(self, client):
        """Test deleting a todo"""
        # Create a todo
        create_response = client.post('/api/todos',
                                     data=json.dumps({"title": "To Delete"}),
                                     content_type='application/json')
        created_data = json.loads(create_response.data)
        todo_id = created_data["data"]["id"]
        
        # Delete the todo
        response = client.delete(f'/api/todos/{todo_id}')
        
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True
        
        # Verify it's deleted
        get_response = client.get(f'/api/todos/{todo_id}')
        assert get_response.status_code == 404
    
    def test_delete_todo_not_found(self, client):
        """Test deleting a non-existent todo returns 404"""
        response = client.delete('/api/todos/999')
        
        assert response.status_code == 404
        data = json.loads(response.data)
        assert data["success"] is False
    
    def test_invalid_endpoint(self, client):
        """Test accessing an invalid endpoint returns 404"""
        response = client.get('/invalid/endpoint')
        
        assert response.status_code == 404
        data = json.loads(response.data)
        assert data["success"] is False
